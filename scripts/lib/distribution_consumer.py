"""Measured relocated public header/link/runtime proof; no private build inputs."""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile

from distribution_aggregate import canonical, macho, regular, sha
from inspect_core_archive import archive_members

LOADS = ["/usr/lib/libSystem.B.dylib", "/usr/lib/libc++.1.dylib", "/usr/lib/libiconv.2.dylib"]
FLAGS = ["-std=c++20", "-stdlib=libc++", "-O3", "-DNDEBUG", "-arch", "arm64",
         "-mmacosx-version-min=14.0", "-DNO_CLIENT_UPDATER"]
FIELDS = {"schema_version", "result", "inputs", "compiler", "sdk_version", "compile_flags",
          "runtime_identity", "header_roots", "header_contexts", "public_header_dependencies", "force_loaded_members",
          "load_commands", "final_system_imports", "resolved_definitions"}
MAIN = b'''#include <airdcpp/stdinc.h>
#include <airdcpp/core/version.h>
#include <iostream>
int main() {
    std::cout << dcpp::getVersionTag() << "\\n" << dcpp::getGitCommit() << "\\n";
}
'''


CONTEXTS = {
    "airdcpp/core/localization/StringDefs.h": dict(parent="airdcpp/core/localization/ResourceManager.h",
        reason="enum fragment included inside ResourceManager class, not a global root"),
    "airdcpp/core/crypto/pubkey.h": dict(parent="airdcpp/core/update/UpdateManager.h",
        reason="qualified UpdateManager static-member definition requires prior class declaration"),
}


def _core_headers(headers):
    return sorted(row["path"].removeprefix("include/") for row in headers
                  if row["component"] == "core" and row["path"].endswith(".h"))


def _roots(headers):
    return [name for name in _core_headers(headers) if name != "airdcpp/core/localization/StringDefs.h"]


def _contexts(headers):
    return {name: value for name, value in CONTEXTS.items() if name in _core_headers(headers)}


def _probe(headers):
    prefix = "#include <airdcpp/stdinc.h>\n"
    if "airdcpp/core/crypto/pubkey.h" in _core_headers(headers):
        prefix += "#include <airdcpp/core/update/UpdateManager.h>\n"
    return (prefix + "".join("#include <" + name + ">\n" for name in _roots(headers))).encode()


def _binding(package, headers):
    for row in headers:
        if sha(regular(package / row["path"])) != row["sha256"]:
            raise ValueError("consumer header input binding differs")
    return dict(archive_sha256=sha(regular(package / "lib/libairdcpp.a")),
                headers_sha256=sha(canonical(headers)), header_probe_sha256=sha(_probe(headers)),
                identity_probe_sha256=sha(MAIN))


def map_members(raw):
    # Symbol annotations in Apple's map need not be UTF-8. Only canonical
    # ASCII member identities from its object table are construction evidence.
    return [name.decode("ascii") for name in re.findall(rb"libairdcpp\.a\(([^)]+)\)", raw)]


def validate_consumer_proof(package, headers, identity, proof):
    package = Path(package)
    if (set(proof) != FIELDS or proof["schema_version"] != 1 or proof["result"] != "PASS"
            or proof["inputs"] != _binding(package, headers)):
        raise ValueError("consumer proof input binding/schema differs")
    if (proof["runtime_identity"] != identity or proof["compile_flags"] != FLAGS
            or proof["header_roots"] != _roots(headers) or proof["load_commands"] != LOADS
            or proof["header_contexts"] != _contexts(headers)
            or proof["force_loaded_members"] != len(list(archive_members(package / "lib/libairdcpp.a")))):
        raise ValueError("consumer proof runtime/header/link contract differs")
    compiler = proof["compiler"]
    if (set(compiler) != {"name", "sha256", "version"} or compiler["name"] != "Apple Clang C++"
            or re.fullmatch(r"[0-9a-f]{64}", compiler["sha256"]) is None
            or not compiler["version"].startswith("Apple clang version ") or not proof["sdk_version"]):
        raise ValueError("consumer proof tool identity differs")
    for field in ("public_header_dependencies", "final_system_imports", "resolved_definitions"):
        values = proof[field]
        if not isinstance(values, list) or not all(isinstance(value, str) for value in values) or values != sorted(set(values)):
            raise ValueError("consumer proof inventory differs")
    if not set(_core_headers(headers)).issubset(proof["public_header_dependencies"]):
        raise ValueError("consumer proof public header closure incomplete")
    if any(value.startswith("/") or ".." in Path(value).parts for value in proof["public_header_dependencies"]):
        raise ValueError("consumer proof header path differs")
    definitions = sorted({row["symbol"] for name, payload in archive_members(package / "lib/libairdcpp.a")
                          for row in macho(payload, name)[0]})
    if proof["resolved_definitions"] != definitions:
        raise ValueError("consumer proof source definition inventory differs")
    if set(definitions).intersection(proof["final_system_imports"]):
        raise ValueError("consumer proof final imports contain aggregate definitions")
    return proof


def prove_consumer(package, headers, identity, evidence=None, forbidden_roots=()):
    """Compile a copied Dist in a private directory; normalize measured facts only.

    Every compiler/linker process denies project private inputs and Homebrew.
    The dependency output independently restricts header opens to public Dist
    and the directly discovered Apple SDK/toolchain. Logs/map/executable remain
    private; public evidence contains no relocation paths, UUIDs or timestamps.
    """
    package = Path(package).absolute()
    binding = _binding(package, headers)
    compiler = subprocess.check_output(["/usr/bin/xcrun", "--find", "clang++"], text=True).strip()
    sdk = Path(subprocess.check_output(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()).resolve()
    sdk_version = subprocess.check_output(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"], text=True).strip()
    compiler_identity = dict(name="Apple Clang C++", sha256=sha(regular(Path(compiler).resolve())),
        version=subprocess.check_output([compiler, "--version"], text=True).splitlines()[0])
    if not compiler_identity["version"].startswith("Apple clang version "):
        raise ValueError("consumer requires the Apple compiler")
    toolchain = Path(compiler).parent.parent.resolve()
    forbidden = [Path(p).absolute() for p in forbidden_roots] + [Path("/opt/homebrew"), Path("/usr/local")]
    with tempfile.TemporaryDirectory(prefix="airdc-dist-consumer-", dir="/private/tmp") as temporary:
        work = Path(temporary)
        dist = work / "Dist"
        shutil.copytree(package, dist)
        (work / "header-probe.cpp").write_bytes(_probe(headers))
        (work / "identity.cpp").write_bytes(MAIN)
        environment = {"PATH": "/usr/bin:/bin", "HOME": str(work), "TMPDIR": str(work), "LC_ALL": "C"}
        profile = '(version 1)(allow default)(deny network*)' + ''.join(
            '(deny file-read* (subpath ' + json.dumps(str(path)) + '))' for path in forbidden)
        if not Path("/usr/bin/sandbox-exec").is_file():
            raise ValueError("consumer input confinement unavailable")
        logs = {}
        def run(name, argv, label):
            result = subprocess.run(["/usr/bin/sandbox-exec", "-p", profile, *argv], cwd=work,
                env=environment, text=True, capture_output=True)
            logs[name] = dict(argv=argv, status=result.returncode, stdout=result.stdout, stderr=result.stderr)
            if evidence is not None:
                output = Path(evidence)
                output.mkdir(parents=True, exist_ok=True)
                (output / (name + ".json")).write_bytes(canonical(logs[name]))
            if result.returncode:
                raise ValueError(label + " failed: " + result.stderr[-3000:])
            return result.stdout
        common = [compiler, *FLAGS, "-isysroot", str(sdk), "-I" + str(dist / "include"),
                  "-I" + str(dist / "include/airdcpp")]
        run("headers", [*common, "-fsyntax-only", "-MD", "-MF", str(work / "headers.d"),
            str(work / "header-probe.cpp")], "public header closure")
        raw_dependencies = regular(work / "headers.d").decode().replace("\\\n", " ").partition(":")[2]
        public_dependencies = []
        for raw in shlex.split(raw_dependencies):
            path = Path(raw).resolve()
            if path == work / "header-probe.cpp":
                continue
            if path.is_relative_to(dist / "include"):
                public_dependencies.append(path.relative_to(dist / "include").as_posix())
            elif not path.is_relative_to(sdk) and not path.is_relative_to(toolchain):
                raise ValueError("public header closure reached an undeclared input: " + str(path))
        executable = work / "consumer"
        link_map = work / "consumer.map"
        run("link", [*common, str(work / "identity.cpp"),
            "-Wl,-force_load," + str(dist / "lib/libairdcpp.a"), str(sdk / "usr/lib/libiconv.tbd"),
            "-Wl,-map," + str(link_map), "-o", str(executable)], "force-loaded consumer link")
        runtime = run("runtime", [str(executable)], "consumer runtime identity").splitlines()
        if runtime != [identity["tag"], identity["commit"]]:
            raise ValueError("consumer runtime identity differs")
        loads = run("load-commands", ["/usr/bin/otool", "-L", str(executable)], "consumer load commands")
        actual_loads = sorted(line.strip().split(" (", 1)[0] for line in loads.splitlines()[1:] if line.strip())
        if actual_loads != LOADS:
            raise ValueError("consumer system load boundary differs")
        commands = run("macho", ["/usr/bin/otool", "-l", str(executable)], "consumer Mach-O")
        if not re.search(r"\bminos 14\.0\b", commands):
            raise ValueError("consumer deployment policy differs")
        if "arm64" not in run("architecture", ["/usr/bin/lipo", "-archs", str(executable)], "consumer architecture").split():
            raise ValueError("consumer architecture differs")
        members = list(archive_members(dist / "lib/libairdcpp.a"))
        mapped = map_members(regular(link_map))
        if sorted(mapped) != sorted(name for name, payload in members):
            raise ValueError("consumer force-load member inventory differs")
        # ld may localize private-external C++ weak symbols. Their resulting
        # definitions still resolve; restricting nm to globals would hide them.
        defined = sorted(set(run("definitions", ["/usr/bin/nm", "-Uj", str(executable)], "consumer definitions").splitlines()))
        definitions = set()
        for name, payload in members:
            symbols, undefined, deployment = macho(payload, name)
            definitions.update(symbol["symbol"] for symbol in symbols)
        if not definitions.issubset(defined):
            raise ValueError("consumer common/weak definition resolution incomplete")
        imports = sorted(set(run("imports", ["/usr/bin/nm", "-uj", str(executable)], "consumer imports").splitlines()))
        proof = dict(schema_version=1, result="PASS", inputs=binding, compiler=compiler_identity,
            sdk_version=sdk_version, compile_flags=FLAGS, runtime_identity=identity, header_roots=_roots(headers),
            header_contexts=_contexts(headers),
            public_header_dependencies=sorted(set(public_dependencies)), force_loaded_members=len(members),
            load_commands=actual_loads, final_system_imports=imports, resolved_definitions=sorted(definitions))
        if evidence is not None:
            shutil.copyfile(link_map, Path(evidence) / "consumer.map")
            (Path(evidence) / "proof.json").write_bytes(canonical(proof))
        return validate_consumer_proof(package, headers, identity, proof)
