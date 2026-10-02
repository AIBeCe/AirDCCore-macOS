#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
python3 - "$repo" <<'PY'
import json, os, subprocess, tempfile
from pathlib import Path
import sys
ROOT=Path(sys.argv[1]); ADAPTER=ROOT/'scripts/lib/dependencies/build_boost.sh'
TOOL=r'''#!/usr/bin/env python3
import json, os, shutil, sys
from pathlib import Path
name=Path(sys.argv[0]).name; args=sys.argv[1:]
with open(os.environ['FAKE_LOG'],'a') as f: f.write(json.dumps([name,*args])+'\n')
if name=='bootstrap.sh':
    b=Path(sys.argv[0]).parent
    (b/'.prefix').write_text(next(a.split('=',1)[1] for a in args if a.startswith('--prefix=')))
    (b/'b2').write_text('#!/bin/sh\nexec "$FAKE_B2" "$@"\n'); (b/'b2').chmod(0o755)
elif name=='b2':
    expected=['variant=release','link=static','runtime-link=shared','threading=multi','address-model=64','architecture=arm','cxxflags=-arch arm64 -mmacosx-version-min=14.0 -O3 -DNDEBUG','linkflags=-arch arm64 -mmacosx-version-min=14.0','--layout=system','-j3','install']
    if args != expected + ['--prefix=' + next(a.split('=',1)[1] for a in args if a.startswith('--prefix='))]:
        # The adapter must retain the locked vector; prefix may appear once.
        if [a for a in args if not a.startswith('--prefix=')] != expected: sys.exit(41)
    if os.environ.get('FAKE_FAIL') == 'b2': sys.exit(29)
    stage=Path(next(a.split('=',1)[1] for a in args if a.startswith('--prefix=')))
    for p in ('include/boost/regex.hpp','include/boost/thread.hpp','lib/libboost_regex.a','lib/libboost_thread.a','lib/cmake/Boost-1.90.0/BoostConfig.cmake'):
        q=stage/p; q.parent.mkdir(parents=True,exist_ok=True); q.write_text('fixture\n')
elif name=='clang++':
    source=Path(next(a for a in args if a.endswith('.cc'))).read_text()
    out=Path(args[args.index('-o')+1])
    if 'unavailable_boost_api' in source:
        out.write_text('#!/bin/sh\nexit 17\n')
    else:
        out.write_text('#!/bin/sh\necho consumer-run >> "$FAKE_RUN_LOG"\n')
    out.chmod(0o755)
'''
with tempfile.TemporaryDirectory(prefix='airdc-boost-') as td:
 root=Path(td); source=root/'source'; build=root/'build'; stage=root/'stage'; tools=root/'tools'
 for p in (source,build,stage,tools): p.mkdir()
 (source/'LICENSE_1_0.txt').write_text('license\n')
 (source/'bootstrap.sh').write_text(TOOL); (source/'bootstrap.sh').chmod(0o755)
 source_manifest=sorted((p.relative_to(source).as_posix(),p.read_bytes()) for p in source.rglob('*'))
 for n in ('bootstrap.sh','b2','clang++'):
  p=tools/n; p.write_text(TOOL); p.chmod(0o755)
 log=root/'log'; runlog=root/'run'; env={**os.environ,'PATH':str(tools)+os.pathsep+os.environ['PATH'],'CXX':str(tools/'clang++'),'FAKE_B2':str(tools/'b2'),'FAKE_LOG':str(log),'FAKE_RUN_LOG':str(runlog),'SOURCE_DATE_EPOCH':'1764771748'}
 r=subprocess.run([str(ADAPTER),str(source),str(build),str(stage),'3','1764771748'],env=env,text=True,capture_output=True)
 assert r.returncode==0,r.stderr
 commands=[json.loads(x) for x in log.read_text().splitlines()]
 assert commands[0][0]=='bootstrap.sh' and commands[0][1].startswith('--prefix=') and commands[0][2]=='--with-libraries=regex,thread'
 assert commands[1][0]=='b2'
 assert sorted(str(p.relative_to(stage)) for p in stage.rglob('*') if p.is_file())==['LICENSE_1_0.txt','include/boost/regex.hpp','include/boost/thread.hpp','lib/cmake/Boost-1.90.0/BoostConfig.cmake','lib/libboost_regex.a','lib/libboost_thread.a']
 assert runlog.read_text()=='consumer-run\n'
 assert source_manifest==sorted((p.relative_to(source).as_posix(),p.read_bytes()) for p in source.rglob('*'))
 evidence=[json.loads(x) for x in r.stdout.splitlines() if x.startswith('{')]; assert all(x.get('status',0)==0 for x in evidence if x['type']=='status')
 failed=subprocess.run([str(ADAPTER),str(source),str(build),str(stage),'3','1764771748'],env={**env,'FAKE_FAIL':'b2'},text=True,capture_output=True)
 assert failed.returncode==29
 print('boost adapter fixture: OK')
PY
