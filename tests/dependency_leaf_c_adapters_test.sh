#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
python3 - "$repo" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest

ROOT = Path(sys.argv[1])
BZIP2 = ROOT / "scripts/lib/dependencies/build_bzip2.sh"
ZLIB = ROOT / "scripts/lib/dependencies/build_zlib.sh"

TOOL = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

name = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["FAKE_LOG"], "a", encoding="utf-8") as stream:
    stream.write(json.dumps([name, *args]) + "\n")
failure_key = Path(args[-1]).name if name == "clang" else (args[-1] if args else "")
if os.environ.get("FAKE_FAIL") == name + ":" + failure_key:
    sys.exit(29)
if name == "make":
    source = Path(args[args.index("-C") + 1])
    if args[-1] == "libbz2.a":
        subprocess.run(["ar", "rcs", str(source / "libbz2.a")], check=True)
elif name == "cmake":
    if args[0] == "--build":
        subprocess.run(["ninja", "-C", args[1], *args[args.index("--target") + 1:]], check=True)
    elif args[0] == "--install":
        build = Path(args[1])
        stage = Path((build / "stage.txt").read_text())
        source = Path((build / "source.txt").read_text())
        for relative in ("include/zlib.h", "include/zconf.h", "LICENSE"):
            target = stage / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source / Path(relative).name, target)
        for relative, data in (("lib/cmake/zlib/ZLIBConfig.cmake", "# fixture\n"),
                               ("lib/cmake/zlib/ZLIBConfigVersion.cmake", "# fixture\n"),
                               ("lib/cmake/zlib/ZLIB-static.cmake", "# fixture\n"),
                               ("lib/cmake/zlib/ZLIB-static-release.cmake", "# fixture\n"),
                               ("lib/pkgconfig/zlib.pc", "prefix=/tmp/stage\nexec_prefix=/tmp/stage\nlibdir=${exec_prefix}/lib\nsharedlibdir=${exec_prefix}/lib\nincludedir=${prefix}/include\nName: zlib\nDescription: zlib compression library\nVersion: 1.3.2\nLicense: Zlib\nLibs: -L${libdir} -lz\nCflags: -I${includedir}\n")):
            target = stage / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(data)
        (stage / "lib").mkdir(exist_ok=True)
        shutil.copyfile(build / "libz.a", stage / "lib/libz.a")
    else:
        build = Path(args[args.index("-B") + 1])
        build.mkdir(parents=True, exist_ok=True)
        (build / "source.txt").write_text(args[args.index("-S") + 1])
        (build / "stage.txt").write_text(next(arg.split("=", 1)[1] for arg in args if arg.startswith("-DCMAKE_INSTALL_PREFIX=")))
elif name == "ninja":
    build = Path(args[args.index("-C") + 1])
    for target in args[args.index("-C") + 2:]:
        if target == "zlibstatic":
            subprocess.run(["ar", "rcs", str(build / "libz.a")], check=True)
        elif target == "zlib_static_example":
            (build / "zlib_static_example").write_text("built\n")
elif name == "ctest":
    if not (Path(args[args.index("--test-dir") + 1]) / "zlib_static_example").exists():
        sys.exit(30)
elif name == "ar":
    Path(args[-1]).write_bytes(b"fixture archive\n")
elif name == "clang":
    source = Path(next(arg for arg in args if arg.endswith(".c")))
    body = source.read_text()
    marker = "BZ2_bzBuffToBuffCompress" if "bzip2" in source.name else "compress2"
    if marker not in body or ("BZ2_bzBuffToBuffDecompress" if marker.startswith("BZ2") else "uncompress") not in body:
        sys.exit(31)
    output = Path(args[args.index("-o") + 1])
    output.write_text("#!/bin/sh\nprintf 'consumer-run\\n' >> \"$FAKE_RUN_LOG\"\n[ \"${FAKE_FAIL:-}\" != consumer:run ]\n")
    output.chmod(0o755)
'''

class AdapterTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="airdc-leaf-c-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.source = self.root / "source with space"
        self.build = self.root / "build with space"
        self.stage = self.root / "stage with space"
        self.tools = self.root / "tools"
        for path in (self.source, self.build, self.stage, self.tools):
            path.mkdir()
        for name in ("make", "cmake", "ctest", "ninja", "clang", "ar"):
            path = self.tools / name
            path.write_text(TOOL)
            path.chmod(0o755)
        self.log = self.root / "commands.jsonl"
        self.run_log = self.root / "run.log"
        self.env = {"PATH": str(self.tools) + os.pathsep + os.environ["PATH"],
                    "CC": str(self.tools / "clang"), "AR": str(self.tools / "ar"),
                    "FAKE_LOG": str(self.log), "FAKE_RUN_LOG": str(self.run_log),
                    "SOURCE_DATE_EPOCH": "1563040227"}
        for name in ("bzlib.h", "zlib.h", "zconf.h", "LICENSE"):
            (self.source / name).write_text(name + "\n")
        self.source_manifest = sorted((p.relative_to(self.source).as_posix(), p.read_bytes()) for p in self.source.rglob("*"))

    def invoke(self, adapter, *, epoch="1563040227", extra=(), failure=None):
        env = dict(self.env)
        env["SOURCE_DATE_EPOCH"] = epoch
        if failure:
            env["FAKE_FAIL"] = failure
        return subprocess.run([str(adapter), str(self.source), str(self.build),
                               str(self.stage), "3", epoch, *extra], env=env,
                              text=True, capture_output=True)

    def commands(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def evidence(self, result):
        return [json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]

    def staged(self):
        return sorted(str(path.relative_to(self.stage)) for path in self.stage.rglob("*") if path.is_file())

    def test_bzip2_exact_make_check_stage_and_installed_consumer(self):
        result = self.invoke(BZIP2)
        self.assertEqual(result.returncode, 0, result.stderr)
        evidence = self.evidence(result)
        self.assertEqual([item["type"] for item in evidence], ["command", "status"] * 4)
        self.assertTrue(all(item.get("status", 0) == 0 for item in evidence if item["type"] == "status"))
        options = ["CC=/usr/bin/clang", "AR=/usr/bin/ar", "RANLIB=/usr/bin/ranlib",
                   "CFLAGS=-O3 -DNDEBUG -D_FILE_OFFSET_BITS=64 -arch arm64 -mmacosx-version-min=14.0"]
        commands = self.commands()
        self.assertEqual(commands[:4], [["make", "-C", str(self.build), "-j", "3", *options, "libbz2.a"],
                                        ["ar", "rcs", str(self.build / "libbz2.a")],
                                        ["make", "-C", str(self.build), "-j", "3", *options, "check"],
                                        ["clang", "-arch", "arm64", "-mmacosx-version-min=14.0",
                                         "-I" + str(self.stage / "include"), str(self.build / "bzip2-consumer.c"),
                                         str(self.stage / "lib/libbz2.a"), "-o", str(self.build / "bzip2-consumer")]])
        self.assertEqual(self.staged(), ["LICENSE", "include/bzlib.h", "lib/libbz2.a"])
        self.assertFalse((self.source / "libbz2.a").exists())
        self.assertEqual(self.run_log.read_text(), "consumer-run\n")
        body = (self.build / "bzip2-consumer.c").read_text()
        for token in ('#include <bzlib.h>', '"AirDCCore"', "BZ2_bzBuffToBuffCompress", "BZ2_bzBuffToBuffDecompress"):
            self.assertIn(token, body)
        self.assertNotIn(str(self.source), body)
        self.assertEqual(self.source_manifest, sorted((p.relative_to(self.source).as_posix(), p.read_bytes()) for p in self.source.rglob("*")))

    def test_zlib_exact_out_of_tree_cmake_ctest_stage_and_installed_consumer(self):
        result = self.invoke(ZLIB, epoch="1771332426")
        self.assertEqual(result.returncode, 0, result.stderr)
        evidence = self.evidence(result)
        self.assertEqual([item["type"] for item in evidence], ["command", "status"] * 6)
        self.assertTrue(all(item.get("status", 0) == 0 for item in evidence if item["type"] == "status"))
        commands = self.commands()
        self.assertEqual(commands[0], ["cmake", "-S", str(self.source), "-B", str(self.build),
                                       "-G", "Ninja", "-DCMAKE_BUILD_TYPE=Release",
                                       "-DZLIB_BUILD_SHARED=OFF", "-DZLIB_BUILD_STATIC=ON",
                                       "-DZLIB_BUILD_TESTING=ON", "-DCMAKE_OSX_ARCHITECTURES=arm64",
                                       "-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0",
                                       "-DCMAKE_INSTALL_PREFIX=" + str(self.stage)])
        self.assertEqual(commands[1:6], [["cmake", "--build", str(self.build), "--parallel", "3", "--target", "zlibstatic", "zlib_static_example"],
                                         ["ninja", "-C", str(self.build), "zlibstatic", "zlib_static_example"],
                                         ["ar", "rcs", str(self.build / "libz.a")],
                                         ["ctest", "--test-dir", str(self.build), "--output-on-failure"],
                                         ["cmake", "--install", str(self.build)]])
        self.assertEqual(commands[6], ["clang", "-arch", "arm64", "-mmacosx-version-min=14.0",
                                       "-I" + str(self.stage / "include"), str(self.build / "zlib-consumer.c"),
                                       str(self.stage / "lib/libz.a"), "-o", str(self.build / "zlib-consumer")])
        self.assertEqual(self.staged(), ["LICENSE", "include/zconf.h", "include/zlib.h",
                                         "lib/cmake/zlib/ZLIB-static-release.cmake", "lib/cmake/zlib/ZLIB-static.cmake",
                                         "lib/cmake/zlib/ZLIBConfig.cmake", "lib/cmake/zlib/ZLIBConfigVersion.cmake",
                                         "lib/libz.a", "lib/pkgconfig/zlib.pc"])
        metadata = (self.stage / "lib/pkgconfig/zlib.pc").read_text()
        self.assertIn("prefix=${pcfiledir}/../..", metadata)
        self.assertIn("exec_prefix=${prefix}", metadata)
        relocated = self.root / "relocated-stage"
        self.stage.rename(relocated)
        lookup = subprocess.run(["pkg-config", "--define-prefix", "--cflags", "--libs",
                                str(relocated / "lib/pkgconfig/zlib.pc")],
                                env=self.env,
                                text=True, capture_output=True)
        self.assertEqual(lookup.returncode, 0, lookup.stderr)
        self.assertIn(f"-I{relocated / 'lib/pkgconfig'}/../../include", lookup.stdout)
        self.assertIn(f"-L{relocated / 'lib/pkgconfig'}/../../lib", lookup.stdout)
        self.assertEqual(self.source_manifest, sorted((p.relative_to(self.source).as_posix(), p.read_bytes()) for p in self.source.rglob("*")))
        self.assertEqual(self.run_log.read_text(), "consumer-run\n")
        body = (self.build / "zlib-consumer.c").read_text()
        for token in ('#include <zlib.h>', '"AirDCCore"', "compress2", "uncompress"):
            self.assertIn(token, body)
        self.assertNotIn(str(self.source), body)
        self.assertEqual(self.source_manifest, sorted((p.relative_to(self.source).as_posix(), p.read_bytes()) for p in self.source.rglob("*")))

    def test_failure_stops_before_install_or_consumer(self):
        for adapter, epoch, failures in ((BZIP2, "1563040227", ("make:libbz2.a", "make:check", "clang:bzip2-consumer")),
                                         (ZLIB, "1771332426", ("cmake:-DCMAKE_INSTALL_PREFIX=" + str(self.stage),
                                                                  "cmake:zlib_static_example", "ctest:--output-on-failure",
                                                                  "cmake:" + str(self.build), "clang:zlib-consumer"))):
            for failure in failures:
                with self.subTest(adapter=adapter.name, failure=failure):
                    self.log.write_text("")
                    if self.run_log.exists(): self.run_log.unlink()
                    for path in sorted(self.stage.rglob("*"), reverse=True):
                        if path.is_file(): path.unlink()
                        elif path.is_dir(): path.rmdir()
                    result = self.invoke(adapter, epoch=epoch, failure=failure)
                    self.assertEqual(result.returncode, 29, result.stderr)
                    statuses = [item for item in self.evidence(result) if item["type"] == "status"]
                    self.assertTrue(statuses)
                    self.assertEqual(statuses[-1]["status"], 29)
                    self.assertFalse(self.run_log.exists())
                    if adapter == BZIP2 and failure.startswith("make:"):
                        self.assertEqual(self.staged(), [])
                    if adapter == ZLIB and failure != "clang:zlib-consumer":
                        self.assertEqual(self.staged(), [])

    def test_consumer_failure_propagates_after_installed_link(self):
        for adapter, epoch in ((BZIP2, "1563040227"), (ZLIB, "1771332426")):
            with self.subTest(adapter=adapter.name):
                self.log.write_text("")
                if self.run_log.exists(): self.run_log.unlink()
                result = self.invoke(adapter, epoch=epoch, failure="consumer:run")
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertEqual(self.run_log.read_text(), "consumer-run\n")
                for path in sorted(self.stage.rglob("*"), reverse=True):
                    if path.is_file(): path.unlink()
                    elif path.is_dir(): path.rmdir()

    def test_rejects_wrong_argv_and_unsafe_paths_before_tools(self):
        for adapter in (BZIP2, ZLIB):
            for extra in (("unexpected-prefix",),):
                result = self.invoke(adapter, extra=extra)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("expected SOURCE BUILD STAGE JOBS EPOCH", result.stderr)
                self.assertFalse(self.log.exists())
            result = subprocess.run([str(adapter), str(self.source), str(self.source),
                                     str(self.stage), "3", "1"], env={**self.env, "SOURCE_DATE_EPOCH": "1"}, text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0, result.stderr)
            self.assertIn("directories must be distinct", result.stderr)
            self.assertFalse(self.log.exists())
            result = subprocess.run([str(adapter), str(self.source), str(self.build),
                                     str(self.stage), "-1", "1"], env={**self.env, "SOURCE_DATE_EPOCH": "1"}, text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0, result.stderr)
            self.assertIn("JOBS must be a positive integer", result.stderr)
            self.assertFalse(self.log.exists())
            result = subprocess.run([str(adapter), str(self.source), str(self.build),
                                     str(self.stage), "3", "1"], env={**self.env, "SOURCE_DATE_EPOCH": "1563040227"}, text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0, result.stderr)
            self.assertIn("epoch disagrees", result.stderr)
            self.assertFalse(self.log.exists())

if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]])
PY
