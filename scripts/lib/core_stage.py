"""One pinned Core staging policy, its version launcher, and read-only validator.

This is deliberately not a general source-patching or generator framework.
Dependency inputs/fingerprints are neither imported nor modified here.
"""
from dataclasses import asdict
from contextlib import contextmanager, ExitStack
from functools import wraps
from inspect import signature
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys

GENERATED = ('airdcpp/core/version.inc', 'airdcpp/core/localization/StringDefs.cpp')
PATCH_PATH = 'config/patches/airdcpp-core-55d51ceb-private-build.patch'
PATCH_TARGETS = ('airdcpp/hash/HashStore.cpp', 'CMakeLists.txt')
CORE_INPUT_FILES = ('config/core-reproducible-policy.json', PATCH_PATH,
                    'scripts/lib/core_stage.py', 'scripts/lib/reproducible_core.sh',
                    'CMakeLists.txt', 'cmake/modules/AirDCCorePolicy.cmake',
                    'cmake/modules/AirDCCoreLinkAdapters.cmake', 'cmake/toolchains/macos-arm64.cmake')
EVIDENCE_FILES = ('core-source-provenance.json', 'original-source-manifest.json',
                  'patched-source-manifest.json', 'staged-source-manifest.json',
                  'version-authority.json', 'core-inputs.json', 'core-input-fingerprint.txt')


def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True)+'\n').encode()


def digest(data):
    return hashlib.sha256(data).hexdigest()


@contextmanager
def bound_directory(path, *, create=False):
    """Hold each ancestor and verify it still occupies its requested name."""
    path = Path(path)
    if not path.is_absolute() or '..' in path.parts:
        raise ValueError(f'unsafe directory: {path}')
    chain = [os.open('/', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)]
    def identity(info):
        return info.st_dev, info.st_ino, info.st_mode
    def check():
        if identity(os.stat('/',follow_symlinks=False)) != identity(os.fstat(chain[0])):
            raise ValueError(f'directory ancestry changed: {path}')
        for index,part in enumerate(path.parts[1:len(chain)]):
            try:
                current=os.stat(part,dir_fd=chain[index],follow_symlinks=False)
            except OSError as error:
                raise ValueError(f'directory ancestry changed: {path}') from error
            if identity(current) != identity(os.fstat(chain[index+1])):
                raise ValueError(f'directory ancestry changed: {path}')
    try:
        for part in path.parts[1:]:
            check()
            try:
                child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=chain[-1])
            except FileNotFoundError:
                if not create:
                    raise
                check()
                os.mkdir(part,0o755,dir_fd=chain[-1])
                child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=chain[-1])
            chain.append(child)
            check()
        yield chain[-1],check
        check()
    finally:
        for fd in reversed(chain):
            os.close(fd)


def directory_fd(path, *, create=False):
    with bound_directory(path,create=create) as (fd,check):
        return os.dup(fd)


def owned_directories(*positions):
    """Bind roots for the duration of one Core authority operation."""
    def decorate(function):
        parameters=tuple(signature(function).parameters)
        @wraps(function)
        def guarded(*args,**kwargs):
            with ExitStack() as stack:
                for position in positions:
                    index,suffix=position if isinstance(position,tuple) else (position,None)
                    path=Path(args[index] if index<len(args) else kwargs[parameters[index]])
                    stack.enter_context(bound_directory(path/suffix if suffix else path))
                return function(*args,**kwargs)
        return guarded
    return decorate


def read_regular(path):
    """No-follow directory traversal and a stable regular-file read."""
    path = Path(path)
    with bound_directory(path.parent) as (parent,check):
        fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
        with os.fdopen(fd, 'rb') as stream:
            before = os.fstat(stream.fileno())
            if not stat.S_ISREG(before.st_mode):
                raise ValueError(f'unsafe regular file: {path}')
            data = stream.read()
            after = os.fstat(stream.fileno())
            current = os.stat(path.name, dir_fd=parent, follow_symlinks=False)
            stable = lambda info: (info.st_dev, info.st_ino, info.st_mode, info.st_size,
                                   info.st_mtime_ns, info.st_ctime_ns)
            if stable(before) != stable(after) or stable(current) != stable(before):
                raise ValueError(f'file changed while reading: {path}')
            check()
            return data, stat.S_IMODE(before.st_mode)


def write_regular(path, data, mode=0o644, epoch=None):
    path = Path(path)
    with bound_directory(path.parent,create=True) as (parent,check):
        check()
        fd = os.open(path.name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                     mode, dir_fd=parent)
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
            os.fchmod(stream.fileno(), mode)
            if epoch is not None:
                os.utime(stream.fileno(), (epoch, epoch))
        check()


def create_directory(path, *, exist_ok=False):
    path=Path(path)
    with bound_directory(path.parent) as (parent,check):
        check()
        try:
            os.mkdir(path.name,0o755,dir_fd=parent)
        except FileExistsError:
            if not exist_ok:
                raise
        with bound_directory(path):
            check()


def rename_owned(source,destination):
    source,destination=map(Path,(source,destination))
    with bound_directory(source.parent) as (old,old_check), bound_directory(destination.parent) as (new,new_check):
        before=os.stat(source.name,dir_fd=old,follow_symlinks=False)
        if not (stat.S_ISREG(before.st_mode) or stat.S_ISDIR(before.st_mode)):
            raise ValueError(f'unsafe preserved entry: {source}')
        old_check(); new_check()
        os.rename(source.name,destination.name,src_dir_fd=old,dst_dir_fd=new)
        after=os.stat(destination.name,dir_fd=new,follow_symlinks=False)
        if (before.st_dev,before.st_ino,before.st_mode)!=(after.st_dev,after.st_ino,after.st_mode):
            raise ValueError('preserved entry identity changed')
        old_check(); new_check()


def set_epoch(path,epoch):
    path=Path(path)
    with bound_directory(path.parent) as (parent,check):
        fd=os.open(path.name,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK,dir_fd=parent)
        try:
            before=os.fstat(fd)
            if not stat.S_ISREG(before.st_mode):
                raise ValueError(f'unsafe timestamp target: {path}')
            check()
            os.utime(fd,(epoch,epoch))
            current=os.stat(path.name,dir_fd=parent,follow_symlinks=False)
            if (before.st_dev,before.st_ino)!=(current.st_dev,current.st_ino):
                raise ValueError(f'timestamp target changed: {path}')
            check()
        finally:
            os.close(fd)


def parse_json(raw):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError(f'duplicate JSON field: {key}')
            result[key] = value
        return result
    return json.loads(raw, object_pairs_hook=pairs)


def json_file(path):
    return parse_json(read_regular(path)[0])


@owned_directories(0,1)
def policy_and_manifest(project, checkout):
    raw = read_regular(project/'config/core-reproducible-policy.json')[0]
    policy = parse_json(raw)
    if set(policy) != {'schema','upstream_commit','source_date_epoch','version','stringdefs_sha256','patch','rationale'}:
        raise ValueError('unexpected Core policy fields')
    if policy['schema'] != 1 or policy['version'] != dict(tag='0.0.0', commit_count=0,
            application_name='AirDCCore-macOS', application_id='org.airdcpp.core.macos.configure'):
        raise ValueError('unreviewed Core version policy')
    patch = policy['patch']
    if set(patch) != {'path','sha256','targets'} or patch['path'] != PATCH_PATH or \
            not isinstance(patch['targets'],list) or \
            [row.get('path') for row in patch['targets']] != list(PATCH_TARGETS) or \
            any(set(row)!={'path','preimage_sha256','postimage_sha256'} for row in patch['targets']):
        raise ValueError('unreviewed Core patch policy')
    for value in (patch['sha256'], policy['stringdefs_sha256'],
                  *(row[field] for row in patch['targets'] for field in ('preimage_sha256','postimage_sha256'))):
        if not isinstance(value, str) or not re.fullmatch('[0-9a-f]{64}', value):
            raise ValueError('invalid Core policy digest')
    patch_bytes = read_regular(project/PATCH_PATH)[0]
    if digest(patch_bytes) != patch['sha256']:
        raise ValueError('Core patch sha256 mismatch')
    headers = re.findall(rb'(?m)^--- a/(.+)\n\+\+\+ b/(.+)\n@@ [^\n]+\n',patch_bytes)
    if headers != [(name.encode(),name.encode()) for name in PATCH_TARGETS] or \
            patch_bytes.count(b'\n@@ ') != 3 or patch_bytes.count(b'--- ') != 2 or patch_bytes.count(b'+++ ') != 2:
        raise ValueError('unexpected sole Core patch structure')
    git_env = {**os.environ, 'GIT_OPTIONAL_LOCKS':'0', 'GIT_NO_REPLACE_OBJECTS':'1'}
    def git(*args):
        return subprocess.check_output(('git','--no-replace-objects','-C',str(checkout),*args), env=git_env)
    pin = git('rev-parse','HEAD').decode().strip()
    if pin != policy['upstream_commit'] or not re.fullmatch('[0-9a-f]{40}', pin):
        raise ValueError('Core pinned commit differs from policy')
    epoch = policy['source_date_epoch']
    if type(epoch) is not int or epoch != int(git('show','-s','--format=%ct',pin)):
        raise ValueError('Core commit epoch differs from policy')
    manifest, contents = [], {}
    for entry in git('ls-tree','-rz',pin).split(b'\0'):
        if not entry:
            continue
        metadata, name = entry.split(b'\t', 1)
        mode, kind, blob = metadata.decode().split()
        relative = os.fsdecode(name)
        if mode not in ('100644','100755') or kind != 'blob':
            raise ValueError(f'unsupported tracked mode: {relative}')
        if relative in GENERATED or '.git' in Path(relative).parts or Path(relative).is_absolute() or '..' in Path(relative).parts:
            raise ValueError(f'unsafe pinned tracked path: {relative}')
        data, actual_mode = read_regular(checkout/relative)
        object_id = hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()
        if object_id != blob or actual_mode != int(mode,8) & 0o777:
            raise ValueError(f'Core tracked content/mode differs: {relative}')
        manifest.append(dict(path=relative,mode=mode,sha256=digest(data)))
        contents[relative] = data
    manifest.sort(key=lambda row: os.fsencode(row['path']))
    for row in patch['targets']:
        if digest(contents.get(row['path'],b'')) != row['preimage_sha256']:
            raise ValueError('Core patch preimage mismatch: '+row['path'])
    return policy, raw, patch_bytes, manifest, contents


def python_identity(python):
    if python != sys.executable or not Path(python).is_absolute():
        raise ValueError('Core Python authority differs')
    resolved = Path(python).resolve(strict=True)
    return dict(invocation_path=python, resolved_path=str(resolved),
                sha256=digest(read_regular(resolved)[0]), version='Python '+sys.version.split()[0])


def version_bytes(authority):
    version = authority['version']
    return ('#define GIT_TAG "'+version['tag']+'"\n#define GIT_COMMIT "'+authority['upstream_commit']+'"\n'
            '#define GIT_COMMIT_COUNT 0\n#define VERSION_DATE '+str(authority['source_date_epoch'])+'\n'
            '#define APPNAME_INC "'+version['application_name']+'"\n'
            '#define APPID_INC "'+version['application_id']+'"\n').encode()


def authority_document(policy, contents, stage, python):
    return dict(schema=1, staged_root=str(stage), upstream_commit=policy['upstream_commit'],
                source_date_epoch=policy['source_date_epoch'], version=policy['version'],
                python=python_identity(python), generator_path='scripts/generate_version.py',
                generator_sha256=digest(contents['scripts/generate_version.py']),
                output_path=GENERATED[0])


def inputs_document(project, manifest, patched, authority, tools, python):
    return dict(schema=1,
                implementation=[dict(path=relative,sha256=digest(read_regular(project/relative)[0]))
                                for relative in CORE_INPUT_FILES],
                original_manifest_sha256=digest(canonical(manifest)),
                patched_manifest_sha256=digest(canonical(patched)),
                version_authority_sha256=digest(canonical(authority)),
                tool_inventory=asdict(tools), python=python_identity(python))


def patch_tool(tools):
    from dependency_build import _pinned_tools
    invocation = _pinned_tools(tools.host,tools.identities,'host')['patch']
    identity = tools.identities['host.patch']
    if invocation != '/usr/bin/patch' or Path(invocation).resolve(strict=True) != Path(identity['resolved_path']) or \
            digest(read_regular(Path(identity['resolved_path']))[0]) != identity['sha256']:
        raise ValueError('Core requires inventoried Apple patch')
    return invocation


@owned_directories(0,1)
def preserve_core_attempt(output, checkout):
    """Move only owned prior output to a numbered recoverable forensic record."""
    output, checkout = map(Path, (output, checkout))
    os.close(directory_fd(output))
    previous = sorted((p for p in output.iterdir() if p.name != 'attempts'),key=lambda p:os.fsencode(p.name))
    if not previous:
        return None
    inventory = []
    for top in previous:
        for path in (top, *sorted(top.rglob('*'))) if top.is_dir() else (top,):
            info = path.lstat()
            row = dict(path=path.relative_to(output).as_posix(),mode=stat.S_IMODE(info.st_mode),
                       device=info.st_dev,inode=info.st_ino,mtime_ns=info.st_mtime_ns)
            if stat.S_ISREG(info.st_mode):
                row.update(kind='file',sha256=digest(read_regular(path)[0]))
            elif stat.S_ISDIR(info.st_mode):
                os.close(directory_fd(path))
                row.update(kind='directory')
            else:
                raise ValueError(f'unsafe prior Core output: {path}')
            inventory.append(row)
    generated = []
    for relative in GENERATED:
        path = checkout/relative
        if path.exists() or path.is_symlink():
            data,mode = read_regular(path)
            info = path.lstat()
            generated.append((relative,data,mode,dict(path=relative,sha256=digest(data),
                device=info.st_dev,inode=info.st_ino,mtime_ns=info.st_mtime_ns,mode=mode)))
    attempts = output/'attempts'
    create_directory(attempts,exist_ok=True)
    os.close(directory_fd(attempts))
    numbers=[]
    for path in attempts.iterdir():
        if not re.fullmatch('[0-9]{4,}',path.name):
            raise ValueError('unexpected preserved Core attempt name')
        os.close(directory_fd(path))
        numbers.append(int(path.name))
    destination=attempts/f'{max(numbers,default=0)+1:04d}'
    create_directory(destination)
    for path in previous:
        rename_owned(path,destination/path.name)
    for row in inventory:
        if row['kind']=='file' and digest(read_regular(destination/row['path'])[0])!=row['sha256']:
            raise ValueError('preserved Core attempt hash differs')
    write_regular(destination/'prior-output-manifest.json',canonical(inventory))
    for relative,data,mode,unused in generated:
        write_regular(destination/'source-generated-forensics'/relative,data,mode)
    write_regular(destination/'source-generated-forensics.json',canonical([row for unused,data,mode,row in generated]))
    return destination


@owned_directories(0,1,2)
def prepare_core_source(project, checkout, output, tools, environment, python):
    project, checkout, output = map(Path,(project,checkout,output))
    policy, unused, patch, original, contents = policy_and_manifest(project,checkout)
    os.close(directory_fd(output))
    stage = output/'source'
    create_directory(stage)  # No overwrite or reuse of unvalidated prior state.
    return populate_core_source(project,checkout,output,tools,environment,python,policy,patch,original,contents)


@owned_directories(0,1,2,(2,'source'))
def populate_core_source(project,checkout,output,tools,environment,python,policy,patch,original,contents):
    stage=output/'source'
    for row in original:
        write_regular(stage/row['path'],contents[row['path']],int(row['mode'],8)&0o777,policy['source_date_epoch'])
    snapshot = output/'core-patch.snapshot'
    write_regular(snapshot,patch)
    result = subprocess.run((patch_tool(tools),'--batch','--forward','--verbose','--fuzz=0','--no-backup-if-mismatch',
                             '-p1','-d',str(stage),'-i',str(snapshot)),env=environment,capture_output=True)
    write_regular(output/'core-patch.log',result.stdout+result.stderr)
    write_regular(output/'core-patch-exit-code.txt',str(result.returncode).encode()+b'\n')
    postimages={row['path']:row['postimage_sha256'] for row in policy['patch']['targets']}
    if result.returncode or any(digest(read_regular(stage/name)[0]) != value for name,value in postimages.items()):
        raise ValueError('Core patch postimage mismatch or application failed; '+
                         (result.stdout+result.stderr).decode(errors='replace')[-1200:])
    # patch may choose current filesystem time; pin the owned patched input too.
    for name in postimages:
        set_epoch(stage/name,policy['source_date_epoch'])
    patched = [dict(row,sha256=postimages[row['path']]) if row['path'] in postimages else row for row in original]
    authority = authority_document(policy,contents,stage,python)
    inputs = inputs_document(project,original,patched,authority,tools,python)
    for name,value in (('original-source-manifest.json',original),('patched-source-manifest.json',patched),
                       ('staged-source-manifest.json',patched),('version-authority.json',authority),('core-inputs.json',inputs)):
        write_regular(output/name,canonical(value))
    fingerprint = digest(canonical(inputs))
    write_regular(output/'core-input-fingerprint.txt',fingerprint.encode()+b'\n')
    provenance = dict(schema=1,original_root=str(checkout),staged_root=str(stage),header_root=str(stage/'airdcpp'),
                      upstream_commit=policy['upstream_commit'],source_date_epoch=policy['source_date_epoch'],
                      original_manifest_sha256=digest(canonical(original)),patched_manifest_sha256=digest(canonical(patched)),
                      staged_manifest_sha256=digest(canonical(patched)),version_authority_sha256=digest(canonical(authority)),
                      core_input_fingerprint=fingerprint,complete=False)
    write_regular(output/'core-source-provenance.json',canonical(provenance))
    checked_stage(project,checkout,output,tools,python,False)
    return dict(provenance,version_authority=str(output/'version-authority.json'))


@owned_directories(0,1,2,(2,'source'))
def checked_stage(project,checkout,output,tools,python,complete):
    policy, unused, unused_patch, original, contents = policy_and_manifest(project,checkout)
    stage=output/'source'
    os.close(directory_fd(stage))
    postimages={row['path']:row['postimage_sha256'] for row in policy['patch']['targets']}
    patched=[dict(row,sha256=postimages[row['path']]) if row['path'] in postimages else row for row in original]
    authority=authority_document(policy,contents,stage,python)
    inputs=inputs_document(project,original,patched,authority,tools,python)
    expected=dict(original_manifest_sha256=digest(canonical(original)),patched_manifest_sha256=digest(canonical(patched)),
                  version_authority_sha256=digest(canonical(authority)),core_input_fingerprint=digest(canonical(inputs)))
    for name,value in (('original-source-manifest.json',original),('patched-source-manifest.json',patched),
                       ('version-authority.json',authority),('core-inputs.json',inputs)):
        if read_regular(output/name)[0] != canonical(value):
            raise ValueError(f'Core authority differs: {name}')
    if read_regular(output/'core-input-fingerprint.txt')[0] != (expected['core_input_fingerprint']+'\n').encode():
        raise ValueError('Core input fingerprint differs')
    rows={row['path']:row for row in patched}
    if complete:
        rows[GENERATED[0]]=dict(path=GENERATED[0],mode='100644',sha256=digest(version_bytes(authority)))
        rows[GENERATED[1]]=dict(path=GENERATED[1],mode='100644',sha256=policy['stringdefs_sha256'])
    found=set()
    for path in stage.rglob('*'):
        relative=path.relative_to(stage).as_posix()
        if path.is_symlink():
            raise ValueError(f'unsafe staged content: {relative}')
        if path.is_dir():
            if not any(name.startswith(relative+'/') for name in rows):
                raise ValueError(f'unexpected staged directory: {relative}')
            continue
        data,mode=read_regular(path)
        if path.lstat().st_nlink != 1:
            raise ValueError(f'unsafe staged hardlink: {relative}')
        row=rows.get(relative)
        if row is None or digest(data)!=row['sha256'] or mode!=int(row['mode'],8)&0o777:
            raise ValueError(f'Core staged content differs: {relative}')
        found.add(relative)
    if found != rows.keys():
        raise ValueError('Core staged content is incomplete')
    manifest=sorted(rows.values(),key=lambda row:os.fsencode(row['path']))
    provenance=dict(schema=1,original_root=str(checkout),staged_root=str(stage),header_root=str(stage/'airdcpp'),
                    upstream_commit=policy['upstream_commit'],source_date_epoch=policy['source_date_epoch'],
                    **expected,staged_manifest_sha256=digest(canonical(manifest)),complete=complete)
    return provenance,manifest


@owned_directories(0,1,2,(2,'source'))
def finalize_core_source(project,checkout,output,tools,python):
    """Only the builder calls this writer after both generators have completed."""
    project,checkout,output=map(Path,(project,checkout,output))
    provenance,manifest=checked_stage(project,checkout,output,tools,python,True)
    for name,value in (('staged-source-manifest.json',manifest),('core-source-provenance.json',provenance)):
        # Replace owned regular evidence only; never follow a symlink.
        with bound_directory(output) as (parent,check):
            read_regular(output/name)
            check()
            os.unlink(name,dir_fd=parent)
            write_regular(output/name,canonical(value))
            check()
    return provenance


@owned_directories(0,1,2,(2,'source'))
def validate_core_source(project,checkout,output,tools,python):
    """Read-only consumer API. Recompute authority from live pin/policy/tools.

    No generated bytes, stage file, evidence, timestamp, or source is changed.
    Return validated absolute roots plus the exact evidence filenames to bind.
    """
    project,checkout,output=map(Path,(project,checkout,output))
    provenance,manifest=checked_stage(project,checkout,output,tools,python,True)
    if read_regular(output/'staged-source-manifest.json')[0]!=canonical(manifest) or \
            read_regular(output/'core-source-provenance.json')[0]!=canonical(provenance):
        raise ValueError('Core completed staged provenance differs')
    return dict(provenance,evidence_files=EVIDENCE_FILES)


def launch_version(args):
    if len(args)<4 or args[2]!='--':
        raise ValueError('invalid version argv')
    authority_path=Path(args[0])
    raw=read_regular(authority_path)[0]
    if digest(raw)!=args[1]:
        raise ValueError('version authority sha256 mismatch')
    authority=parse_json(raw)
    if set(authority) != {'schema','staged_root','upstream_commit','source_date_epoch','version',
                          'python','generator_path','generator_sha256','output_path'} or \
            authority['schema'] != 1 or type(authority['source_date_epoch']) is not int or \
            authority['source_date_epoch'] != 1774518197 or \
            not re.fullmatch('[0-9a-f]{40}',authority['upstream_commit']) or \
            authority['version'] != dict(tag='0.0.0',commit_count=0,
                application_name='AirDCCore-macOS',application_id='org.airdcpp.core.macos.configure') or \
            authority['generator_path'] != 'scripts/generate_version.py' or \
            authority['output_path'] != GENERATED[0] or \
            not re.fullmatch('[0-9a-f]{64}',authority['generator_sha256']):
        raise ValueError('unreviewed version authority schema')
    stage=Path(authority['staged_root'])
    return launch_authorized_version(stage.parent,stage,authority_path,authority,args)


@owned_directories(0,1)
def launch_authorized_version(output,stage,authority_path,authority,args):
    if stage!=Path.cwd() or authority_path!=stage.parent/'version-authority.json' or \
            authority['python']!=python_identity(sys.executable):
        raise ValueError('version execution authority differs')
    version=authority['version']
    expected=[sys.executable,'scripts/generate_version.py','./airdcpp/core/version.inc',version['tag'],
              version['application_name'],version['application_id']]
    if args[3:]!=expected:
        raise ValueError('unreviewed version argv')
    if digest(read_regular(stage/authority['generator_path'])[0])!=authority['generator_sha256']:
        raise ValueError('version generator sha256 mismatch')
    target=stage/GENERATED[0]
    data=version_bytes(authority)
    if target.exists() or target.is_symlink():
        if read_regular(target)[0]!=data:
            raise ValueError('existing staged version content differs')
    else:
        write_regular(target,data,epoch=authority['source_date_epoch'])


if __name__=='__main__':
    try:
        if len(sys.argv)<2 or sys.argv[1]!='version':
            raise ValueError('only the reviewed Core version launcher is supported')
        launch_version(sys.argv[2:])
    except (OSError,ValueError,KeyError,TypeError) as error:
        print(f'Core staging: {error}',file=sys.stderr)
        sys.exit(1)
