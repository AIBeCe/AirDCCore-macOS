"""Real, bounded Core staging/Ninja/native tests; never builds the live Core."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'scripts/lib'))
from dependency_build import resolve_tool_inventory, _pinned_tools


class CoreStagingTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue((ROOT/'scripts/lib/core_stage.py').is_file(), 'private pinned Core staging is missing')
        spec = importlib.util.spec_from_file_location('core_stage', ROOT/'scripts/lib/core_stage.py')
        self.core = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.core)
        temp = tempfile.TemporaryDirectory(prefix='airdc-core-stage-', dir='/private/tmp')
        self.addCleanup(temp.cleanup)
        self.project = Path(temp.name)/'project with spaces'
        self.checkout = self.project/'Source/airdcpp-core'
        self.checkout.mkdir(parents=True)
        self.output = self.project/'Build/airdcpp-core/reproducible-release'
        self.output.mkdir(parents=True)
        self.tools = resolve_tool_inventory()
        self.env = {**os.environ, 'PYTHONDONTWRITEBYTECODE':'1', 'GIT_OPTIONAL_LOCKS':'0',
                    'GIT_AUTHOR_DATE':'1774518197 +0000', 'GIT_COMMITTER_DATE':'1774518197 +0000'}
        for relative in ('CMakeLists.txt', 'airdcpp/hash/HashStore.cpp', 'scripts/generate_version.py',
                         'scripts/generate_stringdefs.py', 'airdcpp/core/localization/StringDefs.h'):
            target = self.checkout/relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT/'Source/airdcpp-core'/relative, target)
        (self.checkout/'state.txt').write_text('pinned\n')
        (self.checkout/'.gitignore').write_text('/airdcpp/core/version.inc\n/airdcpp/core/localization/StringDefs.cpp\n')
        subprocess.run(('git','init','-q',str(self.checkout)),check=True)
        for key,value in (('user.name','Tests'),('user.email','tests@example.invalid'),('commit.gpgsign','false')):
            subprocess.run(('git','-C',str(self.checkout),'config',key,value),check=True)
        subprocess.run(('git','-C',str(self.checkout),'add','.'),check=True)
        self.commit()
        self.policy = json.loads((ROOT/'config/core-reproducible-policy.json').read_text())
        self.policy['upstream_commit']=self.pin
        (self.project/'config/patches').mkdir(parents=True)
        shutil.copy2(ROOT/self.policy['patch']['path'], self.project/self.policy['patch']['path'])
        self.write_policy()
        for relative in self.core.CORE_INPUT_FILES:
            if relative == 'config/core-reproducible-policy.json' or relative == self.policy['patch']['path']:
                continue
            path = self.project/relative
            path.parent.mkdir(parents=True,exist_ok=True)
            shutil.copy2(ROOT/relative,path)

    def commit(self):
        subprocess.run(('git','-C',str(self.checkout),'commit','-qm','fixture'),check=True,env=self.env)
        self.pin = subprocess.check_output(('git','-C',str(self.checkout),'rev-parse','HEAD'),text=True).strip()

    def write_policy(self):
        (self.project/'config/core-reproducible-policy.json').write_text(json.dumps(self.policy))

    def prepare(self):
        return self.core.prepare_core_source(self.project,self.checkout,self.output,self.tools,self.env,sys.executable)

    def source_state(self):
        return [(p.relative_to(self.checkout).as_posix(),p.lstat().st_mode,p.lstat().st_ino,
                 p.lstat().st_mtime_ns,p.read_bytes() if p.is_file() else None)
                for p in sorted(self.checkout.rglob('*'))]

    def test_stages_pinned_inputs_preserves_source_and_validates_completed_stage(self):
        for name in self.core.GENERATED:
            path=self.checkout/name
            path.parent.mkdir(parents=True,exist_ok=True)
            path.write_text('forensic original bytes\n')
        before=self.source_state()
        result=self.prepare()
        stage=Path(result['staged_root'])
        self.assertFalse((stage/'.git').exists())
        self.assertTrue(all(not (stage/name).exists() for name in self.core.GENERATED))
        self.assertEqual((stage/'state.txt').read_bytes(),b'pinned\n')
        self.generate(result)
        self.core.finalize_core_source(self.project,self.checkout,self.output,self.tools,sys.executable)
        validated=self.core.validate_core_source(self.project,self.checkout,self.output,self.tools,sys.executable)
        self.assertEqual(validated['staged_root'],str(stage))
        self.assertEqual(before,self.source_state())
        (stage/'state.txt').write_text('tampered\n')
        with self.assertRaisesRegex(ValueError,'staged content'):
            self.core.validate_core_source(self.project,self.checkout,self.output,self.tools,sys.executable)

    def test_rejects_patch_tamper_pin_epoch_and_symlink(self):
        patch=self.project/self.policy['patch']['path']
        original=patch.read_bytes()
        patch.write_bytes(original+b'\n')
        with self.assertRaisesRegex(ValueError,'patch sha256'): self.prepare()
        patch.write_bytes(original)
        for field,value,message in (('upstream_commit','0'*40,'pinned commit'),('source_date_epoch',1,'commit epoch')):
            old=self.policy[field]; self.policy[field]=value; self.write_policy()
            with self.assertRaisesRegex(ValueError,message): self.prepare()
            self.policy[field]=old; self.write_policy()
        patch.unlink(); patch.symlink_to(ROOT/self.policy['patch']['path'])
        with self.assertRaises((OSError,ValueError)): self.prepare()

    def test_rejects_uncommitted_bytes_and_tracked_symlink(self):
        (self.checkout/'state.txt').write_text('changed\n')
        with self.assertRaisesRegex(ValueError,'tracked content'): self.prepare()
        (self.checkout/'state.txt').write_text('pinned\n')
        (self.checkout/'link').symlink_to('state.txt')
        subprocess.run(('git','-C',str(self.checkout),'add','link'),check=True)
        self.commit(); self.policy['upstream_commit']=self.pin; self.write_policy()
        with self.assertRaisesRegex(ValueError,'tracked mode'): self.prepare()

    def test_rejects_git_replacement_tree_while_preserving_declared_head(self):
        original_pin=self.pin
        (self.checkout/'state.txt').write_text('replacement bytes\n')
        subprocess.run(('git','-C',str(self.checkout),'add','state.txt'),check=True)
        self.commit()
        replacement=self.pin
        subprocess.run(('git','-C',str(self.checkout),'reset','--soft',original_pin),check=True)
        subprocess.run(('git','-C',str(self.checkout),'replace',original_pin,replacement),check=True)
        self.assertEqual(subprocess.check_output(('git','-C',str(self.checkout),'rev-parse','HEAD'),text=True).strip(),original_pin)
        with self.assertRaisesRegex(ValueError,'tracked content'):
            self.prepare()

    def test_digest_authority_and_policy_parse_the_verified_read_only(self):
        prepared=self.prepare()
        authority_path=Path(prepared['version_authority'])
        raw=authority_path.read_bytes()
        changed=json.loads(raw); changed['source_date_epoch']=1
        real_read=self.core.read_regular
        reads=[]
        def swapping_read(path):
            if Path(path)==authority_path:
                reads.append(path)
                return (raw if len(reads)==1 else self.core.canonical(changed)),0o644
            return real_read(path)
        stage=Path(prepared['staged_root'])
        args=[str(authority_path),prepared['version_authority_sha256'],'--',sys.executable,
              'scripts/generate_version.py','./airdcpp/core/version.inc','0.0.0',
              'AirDCCore-macOS','org.airdcpp.core.macos.configure']
        with patch.object(self.core,'read_regular',side_effect=swapping_read), patch.object(self.core.Path,'cwd',return_value=stage):
            self.core.launch_version(args)
        self.assertIn(b'VERSION_DATE 1774518197\n',(stage/self.core.GENERATED[0]).read_bytes())
        self.assertEqual(len(reads),1)
        policy_path=self.project/'config/core-reproducible-policy.json'
        policy_raw=policy_path.read_bytes(); changed=json.loads(policy_raw); changed['rationale']='swapped'
        reads.clear()
        def swapping_policy(path):
            if Path(path)==policy_path:
                reads.append(path)
                return (policy_raw if len(reads)==1 else self.core.canonical(changed)),0o644
            return real_read(path)
        with patch.object(self.core,'read_regular',side_effect=swapping_policy):
            policy,verified_raw,*unused=self.core.policy_and_manifest(self.project,self.checkout)
        self.assertEqual(policy,json.loads(verified_raw))
        self.assertEqual(len(reads),1)

    def test_no_follow_writer_never_creates_descendants_of_linked_parent(self):
        outside=self.project/'outside'; outside.mkdir()
        (self.project/'link').symlink_to(outside,target_is_directory=True)
        with self.assertRaises((OSError,ValueError)):
            self.core.write_regular(self.project/'link/created/file.txt',b'forbidden')
        self.assertEqual(list(outside.iterdir()),[])

    def test_regular_helpers_reject_detached_parent_descriptors(self):
        for operation in ('read','write'):
            with self.subTest(operation=operation):
                parent=self.project/operation; parent.mkdir()
                (parent/'value').write_bytes(b'owned')
                moved=self.project/(operation+'-moved')
                real_open=os.open; swapped=False
                def rename_after_open(path,flags,*args,**kwargs):
                    nonlocal swapped
                    fd=real_open(path,flags,*args,**kwargs)
                    if not swapped and path==parent.name and flags & os.O_DIRECTORY:
                        swapped=True; parent.rename(moved); parent.mkdir()
                    return fd
                with patch.object(self.core.os,'open',side_effect=rename_after_open):
                    with self.assertRaisesRegex(ValueError,'directory.*changed'):
                        if operation=='read': self.core.read_regular(parent/'value')
                        else: self.core.write_regular(parent/'created',b'outside')
                self.assertFalse((moved/'created').exists())

    def test_completed_validator_rejects_stage_ancestry_replacement(self):
        prepared=self.prepare(); self.generate(prepared)
        self.core.finalize_core_source(self.project,self.checkout,self.output,self.tools,sys.executable)
        stage=Path(prepared['staged_root']); moved=self.project/'detached-stage'
        real_read=self.core.read_regular; swapped=False
        def replacing_stage(path):
            nonlocal swapped
            result=real_read(path)
            if not swapped and Path(path)==stage/'state.txt':
                swapped=True; stage.rename(moved); shutil.copytree(moved,stage)
            return result
        with patch.object(self.core,'read_regular',side_effect=replacing_stage):
            with self.assertRaisesRegex(ValueError,'directory.*changed'):
                self.core.validate_core_source(self.project,self.checkout,self.output,self.tools,sys.executable)

    def test_finalization_and_forensic_writers_reject_root_rename(self):
        prepared=self.prepare(); self.generate(prepared)
        stage=Path(prepared['staged_root'])
        real_write=self.core.write_regular
        def replacing_after_final_write(path,*args,**kwargs):
            result=real_write(path,*args,**kwargs)
            if Path(path)==self.output/'core-source-provenance.json':
                moved=self.project/'detached-final-stage'
                stage.rename(moved); shutil.copytree(moved,stage)
            return result
        with patch.object(self.core,'write_regular',side_effect=replacing_after_final_write):
            with self.assertRaisesRegex(ValueError,'directory.*changed'):
                self.core.finalize_core_source(self.project,self.checkout,self.output,self.tools,sys.executable)
        def replacing_after_forensic_write(path,*args,**kwargs):
            result=real_write(path,*args,**kwargs)
            if Path(path).name=='source-generated-forensics.json':
                moved=self.project/'detached-forensic-output'
                self.output.rename(moved); shutil.copytree(moved,self.output)
            return result
        with patch.object(self.core,'write_regular',side_effect=replacing_after_forensic_write):
            with self.assertRaisesRegex(ValueError,'directory.*changed'):
                self.core.preserve_core_attempt(self.output,self.checkout)

    def test_readonly_validator_rejects_external_hardlink_alias(self):
        prepared=self.prepare(); self.generate(prepared)
        self.core.finalize_core_source(self.project,self.checkout,self.output,self.tools,sys.executable)
        os.link(Path(prepared['staged_root'])/'state.txt',self.project/'external-alias')
        with self.assertRaisesRegex(ValueError,'staged hardlink'):
            self.core.validate_core_source(self.project,self.checkout,self.output,self.tools,sys.executable)

    def generate(self,result):
        stage=Path(result['staged_root'])
        args=[sys.executable,str(self.project/'scripts/lib/core_stage.py'),'version',
              result['version_authority'],result['version_authority_sha256'],'--',sys.executable,
              'scripts/generate_version.py','./airdcpp/core/version.inc','0.0.0',
              'AirDCCore-macOS','org.airdcpp.core.macos.configure']
        subprocess.run(args,cwd=stage,check=True,env=self.env)
        subprocess.run((sys.executable,'scripts/generate_stringdefs.py','./airdcpp/core/localization/'),
                       cwd=stage,check=True,env=self.env)
        return args

    def test_real_ninja_deterministic_version_strict_argv_authority_and_no_network(self):
        result=self.prepare(); stage=Path(result['staged_root']); before=self.source_state()
        source=self.project/'ninja-fixture'; source.mkdir()
        upstream=(stage/'CMakeLists.txt').read_text()
        version_block=upstream[upstream.index('if (NOT CMAKE_BUILD_TYPE STREQUAL Debug'):upstream.index('# Stringdefs')]
        (source/'CMakeLists.txt').write_text(f'''cmake_minimum_required(VERSION 3.25)
project(airdcpp NONE)
set(PROJECT_SOURCE_DIR "{stage}")
add_custom_target(airdcpp)
include("{ROOT}/cmake/modules/AirDCCorePolicy.cmake")
set(AIRDCCORE_STAGED_SOURCE_DIR "{stage}")
set(AIRDCCORE_VERSION_AUTHORITY "{result['version_authority']}")
set(AIRDCCORE_VERSION_AUTHORITY_SHA256 "{result['version_authority_sha256']}")
set(AIRDCCORE_VERSION_ADAPTER "{self.project}/scripts/lib/core_stage.py")
set(PYTHON_EXECUTABLE "{sys.executable}")
set(VERSION 0.0.0)
set(TAG_APPLICATION AirDCCore-macOS)
set(APPLICATION_ID org.airdcpp.core.macos.configure)
airdcpp_define_core_version_command()
'''+version_block)
        binary=self.project/'ninja-build'
        configured=subprocess.run((self.tools.host['cmake'],'-S',str(source),'-B',str(binary),'-G','Ninja'),text=True,capture_output=True)
        self.assertEqual(configured.returncode,0,configured.stdout+configured.stderr)
        denied=subprocess.run((self.tools.host['cmake'],'-S',str(source),'-B',str(self.project/'unknown-command'),
                               '-G','Ninja','-DAIRDCCORE_VERSION_COMMAND=evil'),text=True,capture_output=True)
        self.assertNotEqual(denied.returncode,0)
        self.assertIn('unreviewed Core version command authority',denied.stdout+denied.stderr)
        previous=None
        for unused in range(2):
            built=subprocess.run((self.tools.host['cmake'],'--build',str(binary)),text=True,capture_output=True)
            self.assertEqual(built.returncode,0,built.stdout+built.stderr)
            self.assertNotIn('Not using a Git version',built.stdout)
            generated=(stage/'airdcpp/core/version.inc').read_bytes()
            if previous is not None: self.assertEqual(generated,previous)
            previous=generated
        self.assertIn(b'#define VERSION_DATE 1774518197\n',previous)
        self.assertIn(('#define GIT_COMMIT "'+self.pin+'"\n').encode(),previous)
        self.assertEqual(before,self.source_state())
        args=self.generate(result); args[-1]='wrong.app'
        denied=subprocess.run(args,cwd=stage,text=True,capture_output=True)
        self.assertNotEqual(denied.returncode,0); self.assertIn('version argv',denied.stderr)
        authority=Path(result['version_authority']); authority.write_bytes(authority.read_bytes()+b'\n')
        denied=subprocess.run((self.tools.host['cmake'],'--build',str(binary)),text=True,capture_output=True)
        self.assertNotEqual(denied.returncode,0); self.assertIn('version authority sha256',denied.stdout+denied.stderr)
        cmake_text=(source/'CMakeLists.txt').read_text()
        (source/'CMakeLists.txt').write_text(cmake_text.replace('airdcpp_define_core_version_command()',''))
        denied=subprocess.run((self.tools.host['cmake'],'-S',str(source),'-B',str(self.project/'missing-command'),
                               '-G','Ninja'),text=True,capture_output=True)
        self.assertNotEqual(denied.returncode,0)
        self.assertIn('Private Core version command authority is required',denied.stdout+denied.stderr)

    def test_actual_patched_callback_native_valid_short_and_long_keys(self):
        stage=Path(self.prepare()['staged_root'])
        text=(stage/'airdcpp/hash/HashStore.cpp').read_text()
        start=text.index('hashDb->remove_if([&](void* aKey',text.index('TTHValue curRoot;'))
        start=text.index('{',start)+1; end=text.index('auto i = usedRoots.find(curRoot);',start)
        cpp=self.project/'bounds.cpp'
        cpp.write_text('''#include <cstdint>
#include <cstring>
#include <stdexcept>
#include <cassert>
#include <initializer_list>
struct Base { protected: ~Base() {} };
struct TTHValue: Base { uint8_t data[24]; };
using DbException=std::runtime_error;
int main() { TTHValue curRoot; unsigned char key[25]; memset(key,7,sizeof(key));
auto copy=[&](void* aKey,size_t key_len) {
'''+text[start:end]+''' };
copy(key,24); for(auto byte:curRoot.data) assert(byte==7);
for(size_t length:{size_t(0),size_t(23),size_t(25)}) {
 memset(curRoot.data,9,sizeof(curRoot.data)); bool rejected=false;
 try {copy(key,length);} catch(const DbException&) {rejected=true;}
 assert(rejected); for(auto byte:curRoot.data) assert(byte==9);
}}
''')
        binary=self.project/'bounds'
        cxx=_pinned_tools(self.tools.apple,self.tools.identities,'apple')['cxx']
        flags=(cxx,'-isysroot',self.tools.sdkroot,'-std=c++20','-Werror','-Wthread-safety')
        patched=cpp.read_text()
        old=(ROOT/'Source/airdcpp-core/airdcpp/hash/HashStore.cpp').read_text()
        old_start=old.index('hashDb->remove_if([&](void* aKey',old.index('TTHValue curRoot;'))
        old_start=old.index('{',old_start)+1
        old_end=old.index('auto i = usedRoots.find(curRoot);',old_start)
        cpp.write_text(patched.replace(text[start:end],old[old_start:old_end]))
        baseline=subprocess.run((*flags,str(cpp),'-o',str(binary)),text=True,capture_output=True)
        self.assertNotEqual(baseline.returncode,0)
        self.assertIn('nontrivial-memcall',baseline.stderr)
        cpp.write_text(patched)
        compiled=subprocess.run((*flags,str(cpp),'-o',str(binary)),text=True,capture_output=True)
        self.assertEqual(compiled.returncode,0,compiled.stdout+compiled.stderr)
        subprocess.run((str(binary),),check=True)


if __name__=='__main__': unittest.main(verbosity=2)
