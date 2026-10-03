"""Offline command fixtures that compile, link and run real ARM64 consumers.

Declaration slices are bound to the exact release archives pinned in the lock:
miniupnpc 2.3.3 include/{miniupnpc.h,upnpdev.h}; MaxMindDB 1.13.3
include/maxminddb.h; OpenSSL 3.5.8 include/openssl/{ssl.h.in,evp.h}.
The install layouts follow their CMakeLists.txt and exporters/build.info.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import shlex
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/lib"))
from dependency_lock import load_lock
from dependency_prefix import validate_prefix

RECORDS = {r.name: r for r in load_lock(ROOT / "config/dependencies.lock").dependencies
           if r.name in ("openssl", "miniupnpc", "libmaxminddb")}
PINS = {"openssl": "a8f84a39918ec6415ce765d9b429d313ba97b8143169c172e734b9514464f5b2",
        "miniupnpc": "d52a0afa614ad6c088cc9ddff1ae7d29c8c595ac5fdd321170a05f41e634bd1a",
        "libmaxminddb": "a66502ea76eadbe17f2cd6fd708946777253972d2ae8157dee1b23a2fb528171"}
HEADERS = {
    "include/miniupnpc/miniupnpc.h": '#define MINIUPNPC_VERSION "2.3.3"\nstruct UPNPDev;\nvoid freeUPNPDevlist(struct UPNPDev * devlist);\n',
    "include/maxminddb.h": 'extern const char *MMDB_lib_version(void);\n',
    "include/openssl/ssl.h": '#include <stddef.h>\n#include <stdint.h>\ntypedef struct ssl_ctx_st SSL_CTX;\ntypedef struct ssl_method_st SSL_METHOD;\ntypedef struct ossl_init_settings_st OPENSSL_INIT_SETTINGS;\nint OPENSSL_init_ssl(uint64_t opts, const OPENSSL_INIT_SETTINGS *settings);\nconst SSL_METHOD *TLS_method(void);\nSSL_CTX *SSL_CTX_new(const SSL_METHOD *meth);\nvoid SSL_CTX_free(SSL_CTX *);\n',
    "include/openssl/crypto.h": '/* OpenSSL 3.5.8 crypto fixture. */\n',
    "include/openssl/evp.h": '#include <stddef.h>\n#define EVP_MAX_MD_SIZE 64\ntypedef struct evp_md_st EVP_MD;\ntypedef struct engine_st ENGINE;\nconst EVP_MD *EVP_sha256(void);\nint EVP_Digest(const void *data, size_t count, unsigned char *md, unsigned int *size, const EVP_MD *type, ENGINE *impl);\n',
}
STUBS = {
    "miniupnpc": '#include <miniupnpc/miniupnpc.h>\nvoid freeUPNPDevlist(struct UPNPDev *devlist) { (void)devlist; }\n',
    "maxminddb": '#include <maxminddb.h>\nconst char *MMDB_lib_version(void) { return "1.13.3"; }\n',
    "ssl": '#include <openssl/ssl.h>\nstruct ssl_ctx_st { int value; };\nstruct ssl_method_st { int value; };\nstatic SSL_CTX ctx; static SSL_METHOD method;\nint OPENSSL_init_ssl(uint64_t o, const OPENSSL_INIT_SETTINGS *s) { return o == 0 && s == NULL; }\nconst SSL_METHOD *TLS_method(void) { return &method; }\nSSL_CTX *SSL_CTX_new(const SSL_METHOD *m) { return m == &method ? &ctx : NULL; }\nvoid SSL_CTX_free(SSL_CTX *c) { (void)c; }\n',
    "crypto": '#include <openssl/evp.h>\n#include <string.h>\nstruct evp_md_st { int value; }; static EVP_MD md;\nconst EVP_MD *EVP_sha256(void) { return &md; }\nint EVP_Digest(const void *d, size_t n, unsigned char *out, unsigned int *size, const EVP_MD *m, ENGINE *e) { if (n != 9 || memcmp(d, "AirDCCore", 9) || m != &md || e) return 0; memset(out, 1, 32); *size = 32; return 1; }\n',
}

TOOL = r'''#!/usr/bin/env python3
import json, os, shutil, subprocess, sys
from pathlib import Path
name, args = Path(sys.argv[0]).name, sys.argv[1:]
build, source, stage = [Path(os.environ[k]) for k in ("FIXTURE_BUILD", "FIXTURE_SOURCE", "FIXTURE_STAGE")]
component = os.environ["FIXTURE_COMPONENT"]
if name == "perl": purpose = "configure"
elif name == "make": purpose = "install" if "install_dev" in args else "test" if args[-1] == "test" else "build"
elif name == "cmake": purpose = "build" if args[0] == "--build" else "install" if args[0] == "--install" else "configure"
elif name == "ctest": purpose = "test"
else: purpose = "consumer-compile"
with open(os.environ["FAKE_LOG"], "a") as log: log.write(json.dumps([name, *args]) + "\n")
if purpose == os.environ.get("FAKE_FAIL"): sys.exit(29)
state = build / "fixture-state"
previous = state.read_text() if state.exists() else ""
if purpose != "consumer-compile":
    expected = {"configure": "", "build": "configure", "test": "build", "install": "test"}[purpose]
    if previous != expected: sys.exit(30)
    state.write_text(purpose)
if purpose == "configure" and component == "openssl":
    if Path.cwd() != build or not (build / "Configure").is_file(): sys.exit(32)
    (build / "configured.generated").write_text("private build\n")
if purpose == "build":
    for cfile in source.glob("*.c"):
        obj = build / (cfile.stem + ".o")
        subprocess.run([os.environ["REAL_CC"], "-arch", "arm64", "-mmacosx-version-min=14.0", "-I" + str(source / "include"), "-c", str(cfile), "-o", str(obj)], check=True)
        subprocess.run([os.environ["REAL_AR"], "rcs", str(build / ("lib" + cfile.stem + ".a")), str(obj)], check=True)
elif purpose == "install":
    shutil.copytree(source / "include", stage / "include", dirs_exist_ok=True)
    (stage / "lib/pkgconfig").mkdir(parents=True)
    for archive in build.glob("*.a"): shutil.copyfile(archive, stage / "lib" / archive.name)
    if component == "openssl":
        pc_names, cmake_dir = ("libcrypto", "libssl", "openssl"), "OpenSSL"
        cmake_names = ("OpenSSLConfig.cmake", "OpenSSLConfigVersion.cmake")
    elif component == "miniupnpc":
        pc_names, cmake_dir = ("miniupnpc",), "miniupnpc"
        cmake_names = ("miniupnpc-config.cmake", "miniupnpc-private.cmake", "libminiupnpc-static.cmake", "libminiupnpc-static-release.cmake")
        (stage / "bin").mkdir()
        (stage / "bin/external-ip.sh").write_text("upstream helper\n")
    else:
        pc_names, cmake_dir = ("libmaxminddb",), "maxminddb"
        cmake_names = ("maxminddb-config.cmake", "maxminddb-config-release.cmake")
    if component != "openssl":
        (stage / "share/man/man3").mkdir(parents=True)
        (stage / "share/man/man3/fixture.3").write_text("upstream man page\n")
    for pc_name in pc_names:
        libname = "ssl -lcrypto" if pc_name == "openssl" else pc_name.removeprefix("lib")
        libdir = "lib" if component == "libmaxminddb" else "${prefix}/lib"
        includedir = "include" if component == "libmaxminddb" else "${prefix}/include"
        # miniupnpc's pinned template quotes variable references. pkg-config
        # double-escapes spaces in those references unless relocation normalizes
        # the include/library options to conventional unquoted interpolation.
        library_path = '-L"${libdir}"' if component == "miniupnpc" else '-L${libdir}'
        include_path = '-I"${includedir}"' if component == "miniupnpc" else '-I${includedir}'
        (stage / "lib/pkgconfig" / (pc_name + ".pc")).write_text(f'prefix={stage}\nexec_prefix=${{prefix}}\nlibdir={libdir}\nincludedir={includedir}\nName: {pc_name}\nDescription: locked release fixture\nVersion: {os.environ["FIXTURE_VERSION"]}\nLibs: {library_path} -l{libname}\nCflags: {include_path}\n')
    directory = stage / "lib/cmake" / cmake_dir
    directory.mkdir(parents=True)
    for filename in cmake_names: (directory / filename).write_text(f'# {filename}: upstream export fixture\n')
    config = directory / cmake_names[0]
    if component == "openssl":
        config.write_text('get_filename_component(_prefix "${CMAKE_CURRENT_LIST_DIR}/../../.." ABSOLUTE)\nadd_library(OpenSSL::Crypto STATIC IMPORTED)\nadd_library(OpenSSL::SSL STATIC IMPORTED)\nset_target_properties(OpenSSL::Crypto PROPERTIES IMPORTED_LOCATION "${_prefix}/lib/libcrypto.a" INTERFACE_INCLUDE_DIRECTORIES "${_prefix}/include")\nset_target_properties(OpenSSL::SSL PROPERTIES IMPORTED_LOCATION "${_prefix}/lib/libssl.a" INTERFACE_LINK_LIBRARIES OpenSSL::Crypto INTERFACE_INCLUDE_DIRECTORIES "${_prefix}/include")\n')
    else:
        archive = "libminiupnpc.a" if component == "miniupnpc" else "libmaxminddb.a"
        config.write_text(f'get_filename_component(_prefix "${{CMAKE_CURRENT_LIST_DIR}}/../../.." ABSOLUTE)\nadd_library({cmake_dir}::{cmake_dir} STATIC IMPORTED)\nset_target_properties({cmake_dir}::{cmake_dir} PROPERTIES IMPORTED_LOCATION "${{_prefix}}/lib/{archive}" INTERFACE_INCLUDE_DIRECTORIES "${{_prefix}}/include")\n')
    if os.environ.get("FAKE_MISSING"): (stage / os.environ["FAKE_MISSING"]).unlink()
elif purpose == "consumer-compile":
    if previous != "install": sys.exit(30)
    output = Path(args[args.index("-o") + 1]); actual = output.with_suffix(".real")
    result = subprocess.run([os.environ["REAL_CC"], *[str(actual) if a == str(output) else a for a in args]])
    if result.returncode: sys.exit(result.returncode)
    output.write_text('#!/usr/bin/env python3\nimport os,subprocess,sys\nfrom pathlib import Path\nwith open(os.environ["FAKE_RUN_LOG"], "a") as log: log.write("consumer-run\\n")\nif os.environ.get("FAKE_FAIL") == "consumer-run": sys.exit(37)\nsys.exit(subprocess.run([str(Path(__file__).with_suffix(".real"))]).returncode)\n')
    output.chmod(0o755)
'''


def snapshot(root):
    return [(p.relative_to(root).as_posix(), p.stat().st_mode & 0o777,
             hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() else None)
            for p in sorted(root.rglob("*"))]


class NetworkAdapters(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="airdc-network-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.real_cc = subprocess.check_output(["xcrun", "--find", "clang"], text=True).strip()
        self.real_ar = subprocess.check_output(["xcrun", "--find", "ar"], text=True).strip()
        self.sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()

    def fixture(self, name):
        base = self.root / name; base.mkdir()
        self.source, self.build, self.stage, self.tools = [base / label for label in
            ("source with space", "build with space", "stage with space", "tools")]
        for path in (self.source, self.build, self.stage, self.tools): path.mkdir()
        record = RECORDS[name]
        self.assertEqual(record.source.archive_sha256, PINS[name], "Refresh fixture declarations and install contracts for new source pins")
        for relative, data in HEADERS.items():
            if name == "openssl" and "openssl" in relative or name == "miniupnpc" and "miniupnpc" in relative or name == "libmaxminddb" and "maxminddb" in relative:
                path = self.source / relative; path.parent.mkdir(parents=True, exist_ok=True); path.write_text(data)
        for archive in record.expected_archives:
            key = Path(archive).stem.removeprefix("lib")
            (self.source / (key + ".c")).write_text(STUBS[key])
        for license in record.license_paths: (self.source / license).write_text("Pinned release fixture license\n")
        (self.source / ("Configure" if name == "openssl" else "CMakeLists.txt")).write_text("immutable upstream fixture\n")
        doc = self.source / ("man3" if name == "miniupnpc" else "man/man3")
        doc.mkdir(parents=True)
        (doc / "fixture.3").write_text("upstream man page\n")
        for tool in ("perl", "make", "cmake", "ctest", "clang"):
            path = self.tools / tool; path.write_text(TOOL); path.chmod(0o755)
        self.log, self.run_log = base / "commands.jsonl", base / "run.log"
        self.env = {**os.environ, "PATH": str(self.tools) + os.pathsep + os.environ["PATH"],
            "CC": str(self.tools / "clang"), "SDKROOT": self.sdk, "SOURCE_DATE_EPOCH": str(record.source_date_epoch),
            "REAL_CC": self.real_cc, "REAL_AR": self.real_ar, "FAKE_LOG": str(self.log),
            "FAKE_RUN_LOG": str(self.run_log), "FIXTURE_SOURCE": str(self.source),
            "FIXTURE_BUILD": str(self.build), "FIXTURE_STAGE": str(self.stage),
            "FIXTURE_COMPONENT": name, "FIXTURE_VERSION": record.version}
        self.before = snapshot(self.source)
        return record

    def invoke(self, name, **env):
        return subprocess.run([str(ROOT / "scripts/lib/dependencies" / ("build_" + name + ".sh")),
            str(self.source), str(self.build), str(self.stage), "3", self.env["SOURCE_DATE_EPOCH"]],
            env={**self.env, **env}, text=True, capture_output=True)

    def evidence(self, result):
        return [json.loads(line) for line in result.stdout.splitlines() if line.startswith("{")]

    def test_scripts_are_executable(self):
        for name in RECORDS:
            self.assertTrue(os.access(ROOT / "scripts/lib/dependencies" / ("build_" + name + ".sh"), os.X_OK))
        self.assertTrue(os.access(ROOT / "tests/dependency_leaf_network_adapters_test.sh", os.X_OK))

    def test_exact_commands_consumers_immutable_source_and_strict_prefix(self):
        for name in RECORDS:
            with self.subTest(name=name):
                record = self.fixture(name); result = self.invoke(name)
                self.assertEqual(result.returncode, 0, result.stderr)
                options = [a.replace("@STAGE@", str(self.stage)).replace("@JOBS@", "3") for a in record.configure_options]
                configure = ["perl", str(self.build / "Configure"), *options] if name == "openssl" else ["cmake", "-S", str(self.source), "-B", str(self.build), *options]
                expected = [configure]
                if name == "openssl":
                    build_options = [a.replace("@JOBS@", "3") for a in record.build_options]
                    expected += [["make", "-C", str(self.build), *build_options], ["make", "-C", str(self.build), *build_options, "test"], ["make", "-C", str(self.build), *record.install_options]]
                else: expected += [["cmake", "--build", str(self.build), "--parallel", "3"], ["ctest", "--test-dir", str(self.build), "--output-on-failure"], ["cmake", "--install", str(self.build)]]
                expected += [["clang", "-arch", "arm64", "-mmacosx-version-min=14.0", "-I" + str(self.stage / "include"), str(self.build / (name + "-consumer.c")), *[str(self.stage / a) for a in record.expected_archives], "-o", str(self.build / (name + "-consumer"))]]
                self.assertEqual([json.loads(line) for line in self.log.read_text().splitlines()], expected)
                evidence = self.evidence(result)
                self.assertEqual([e["type"] for e in evidence], ["command", "status"] * 6)
                self.assertEqual([e["purpose"] for e in evidence[::2]], ["configure", "build", "test", "install", "consumer-compile", "consumer-run"])
                for index, command in enumerate(expected):
                    actual = evidence[index * 2]["argv"]
                    self.assertEqual([Path(actual[0]).name, *actual[1:]], command)
                self.assertEqual([e["status"] for e in evidence[1::2]], [0] * 6)
                self.assertEqual(self.run_log.read_text(), "consumer-run\n")
                self.assertEqual(snapshot(self.source), self.before)
                report = validate_prefix(record, self.stage, {"project": self.root, "source": self.source, "build": self.build})
                self.assertEqual(len(report.archives), len(record.expected_archives))
                for archive in report.archives:
                    self.assertEqual(archive.architectures, ("arm64",)); self.assertTrue(archive.defined_symbols)
                for license in record.license_paths: self.assertEqual((self.stage / license).read_bytes(), (self.source / license).read_bytes())
                installed = sorted(p.relative_to(self.stage).as_posix() for p in self.stage.rglob("*") if p.is_file())
                self.assertEqual(installed, sorted([*record.expected_archives, *record.expected_metadata, *record.license_paths, *[h for h in HEADERS if (self.stage / h).exists()]]))
                relocated = self.stage.with_name("relocated stage"); self.stage.rename(relocated)
                validate_prefix(record, relocated, {"project": self.root})
                pc = next(path for path in record.expected_metadata if path.endswith(".pc") and Path(path).stem == name)
                lookup_env = {**self.env, "PKG_CONFIG_LIBDIR": str(relocated / "lib/pkgconfig"), "PKG_CONFIG_PATH": ""}
                lookup = subprocess.run(["pkg-config", "--cflags", "--libs", Path(pc).stem], env=lookup_env, text=True, capture_output=True)
                self.assertEqual(lookup.returncode, 0, lookup.stderr); self.assertIn("relocated", lookup.stdout)
                self.assertNotIn(str(self.stage), lookup.stdout); self.assertNotIn("/opt/homebrew", result.stdout)
                consumer = self.build / (name + "-consumer.c")
                executable = self.build / "relocated-pc-consumer"
                compiled = subprocess.run([self.real_cc, "-arch", "arm64", "-mmacosx-version-min=14.0", str(consumer), *shlex.split(lookup.stdout), "-o", str(executable)], env=self.env, capture_output=True, text=True)
                self.assertEqual(compiled.returncode, 0, compiled.stderr)
                self.assertEqual(subprocess.run([str(executable)]).returncode, 0)
                # Exercise relocated CMake package discovery and imported targets.
                project = self.root / (name + "-cmake-consumer"); project.mkdir()
                package, target = ("OpenSSL", "OpenSSL::SSL") if name == "openssl" else ("miniupnpc", "miniupnpc::miniupnpc") if name == "miniupnpc" else ("maxminddb", "maxminddb::maxminddb")
                (project / "CMakeLists.txt").write_text(f'cmake_minimum_required(VERSION 3.20)\nproject(consumer C)\nfind_package({package} CONFIG REQUIRED PATHS "{relocated}" NO_DEFAULT_PATH)\nadd_executable(consumer "{consumer}")\ntarget_link_libraries(consumer PRIVATE {target})\n')
                configured = subprocess.run(["cmake", "-S", str(project), "-B", str(project / "build"), "-G", "Ninja", "-DCMAKE_OSX_ARCHITECTURES=arm64", "-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0"], env={**os.environ, "SDKROOT": self.sdk}, capture_output=True, text=True)
                self.assertEqual(configured.returncode, 0, configured.stderr)
                built = subprocess.run(["cmake", "--build", str(project / "build")], capture_output=True, text=True)
                self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
                self.assertEqual(subprocess.run([str(project / "build/consumer")]).returncode, 0)

    def test_each_command_failure_preserves_status_and_stops(self):
        for name in RECORDS:
            for purpose in ("configure", "build", "test", "install", "consumer-compile", "consumer-run"):
                with self.subTest(name=name, purpose=purpose):
                    self.fixture(name); result = self.invoke(name, FAKE_FAIL=purpose)
                    status = 37 if purpose == "consumer-run" else 29
                    self.assertEqual(result.returncode, status, result.stderr)
                    self.assertEqual(self.evidence(result)[-1], {"type": "status", "purpose": purpose, "status": status})
                    self.assertEqual(snapshot(self.source), self.before)
                    if purpose in ("configure", "build", "test", "install"): self.assertEqual(list(self.stage.iterdir()), [])
                    shutil.rmtree(self.root / name)

    def test_missing_outputs_fail_before_consumer(self):
        for name, record in RECORDS.items():
            for missing in (*record.expected_headers, *record.expected_archives, *record.expected_metadata):
                with self.subTest(name=name, missing=missing):
                    self.fixture(name); result = self.invoke(name, FAKE_MISSING=missing)
                    self.assertNotEqual(result.returncode, 0); self.assertFalse(self.run_log.exists())
                    self.assertNotIn("consumer-compile", [e["purpose"] for e in self.evidence(result)])
                    shutil.rmtree(self.root / name)

    def test_wrong_version_runtime_and_wrong_public_api_compile_fail(self):
        self.fixture("miniupnpc")
        (self.source / "include/miniupnpc/miniupnpc.h").write_text(HEADERS["include/miniupnpc/miniupnpc.h"].replace('"2.3.3"', '"0.0.0"'))
        result = self.invoke("miniupnpc"); self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(self.evidence(result)[-1]["purpose"], "consumer-run")
        shutil.rmtree(self.root / "miniupnpc")
        self.fixture("libmaxminddb")
        (self.source / "include/maxminddb.h").write_text("extern const char *MMDB_other_version(void);\n")
        result = self.invoke("libmaxminddb"); self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.evidence(result)[-1]["purpose"], "consumer-compile"); self.assertFalse(self.run_log.exists())

    def test_invalid_contract_fails_before_commands(self):
        self.fixture("miniupnpc"); adapter = ROOT / "scripts/lib/dependencies/build_miniupnpc.sh"
        for args in ((str(self.source), str(self.build), str(self.stage), "0", self.env["SOURCE_DATE_EPOCH"]),
                     (str(self.source), str(self.source), str(self.stage), "3", self.env["SOURCE_DATE_EPOCH"]),
                     (str(self.source), str(self.build), str(self.stage), "3", "1")):
            result = subprocess.run([str(adapter), *args], env=self.env, capture_output=True)
            self.assertEqual(result.returncode, 2); self.assertFalse(self.log.exists())


if __name__ == "__main__": unittest.main(verbosity=1)
