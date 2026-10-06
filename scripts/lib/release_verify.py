"""Public verification and the opt-in two-fresh-checkout Gate 8 experiment."""
import argparse
import json
import os
from pathlib import Path
import platform
import stat
import subprocess
import sys
import tempfile

from dependency_acquire import OwnedDirectory, _identity, tree_manifest
from distribution_aggregate import canonical, document, regular, sha
from distribution_package import files_in, verify_package
from public_core_identity import public_core_fingerprint
from release_rehearsal import rehearse_release

GENERATED = ("Source", "Dependencies", "Build", "Dist")
AUTHORITY = ("config/upstream.env", "config/dependencies.lock",
             "config/core-reproducible-policy.json", "config/packaging-core-policy.json")
COMMANDS = (
    ("update", ("scripts/update",)),
    ("dependencies", ("scripts/update", "--dependencies")),
    ("dependency-build", ("scripts/build", "--build-dependencies")),
    ("core", ("scripts/build", "--build-reproducible-core")),
    ("private-consumer", ("scripts/build", "--link-reproducible-consumer")),
    ("package", ("scripts/package",)),
    ("verify", ("scripts/verify",)),
)
ALL_COMMANDS = (
    COMMANDS[:5]
    + tuple(("repeat-" + phase, argv) for phase, argv in COMMANDS[:5])
    + COMMANDS[5:]
    + tuple(("repeat-" + phase, argv) for phase, argv in COMMANDS[5:])
)


class ReleaseError(ValueError):
    def __init__(self, message, evidence):
        super().__init__(message)
        self.evidence = Path(evidence)


def _environment():
    return dict(os.environ, PYTHONDONTWRITEBYTECODE="1", GIT_OPTIONAL_LOCKS="0")


def _git(project, *args):
    return subprocess.check_output(["git", "-c", "core.hooksPath=/dev/null", "-C", str(project), *args],
                                   env=_environment(), stderr=subprocess.STDOUT)


def verify_distribution(project, distribution=None, *, consumer_evidence=None):
    """The existing verifier owns all payload and fresh relocated consumer checks."""
    project = Path(project).absolute()
    distribution = Path(distribution).absolute() if distribution is not None else project / "Dist"
    return verify_package(distribution, project, fresh_consumer=True, consumer_evidence=consumer_evidence)


def distribution_inventory(distribution):
    distribution = Path(distribution).absolute()
    files = files_in(distribution)
    entries = []
    for path in distribution.rglob("*"):
        mode = path.lstat().st_mode
        row = dict(path=path.relative_to(distribution).as_posix(), mode=stat.S_IMODE(mode))
        if stat.S_ISDIR(mode):
            row["type"] = "directory"
        else:
            raw = regular(files[row["path"]])
            row.update(type="file", size=len(raw), sha256=sha(raw))
        entries.append(row)
    return sorted(entries, key=lambda row: row["path"].encode())


def _implementation_inventory(project):
    paths = _git(project, "ls-files", "-z").decode().split("\0")[:-1]
    if any(path.split("/", 1)[0] in GENERATED for path in paths):
        raise ValueError("generated inputs or outputs are tracked")
    return sha(canonical([dict(path=path, mode=stat.S_IMODE((project / path).lstat().st_mode),
                              sha256=sha(regular(project / path))) for path in paths]))


def _authority(project):
    return {path: sha(regular(project / path)) for path in AUTHORITY}


def _host():
    return dict(system=platform.system(), architecture=platform.machine(),
        macos_version=subprocess.check_output(["/usr/bin/sw_vers", "-productVersion"], text=True).strip(),
        macos_build=subprocess.check_output(["/usr/bin/sw_vers", "-buildVersion"], text=True).strip(),
        python_invocation=sys.executable, python_resolved=str(Path(sys.executable).resolve()),
        python_sha256=sha(regular(Path(sys.executable).resolve())), python_version=platform.python_version())


def _noop_snapshot(project):
    result = {}
    for relative in ("Source", "Dependencies", "Build/dependencies", "Build/prefix"):
        root = project / relative
        metadata = []
        for path in (root, *sorted(root.rglob("*"))):
            info = path.lstat()
            metadata.append([path.relative_to(root).as_posix(), info.st_dev, info.st_ino,
                info.st_mode, info.st_size, info.st_mtime_ns, info.st_ctime_ns])
        result[relative] = dict(content_sha256=sha(tree_manifest(root)), metadata_sha256=sha(canonical(metadata)))
    return result


def _execute(project, evidence, phase, argv, commands):
    number = len(commands) + 1
    stem = f"{number:02d}-{phase}"
    log, status = evidence / (stem + ".log"), evidence / (stem + ".status")
    print(f"Gate 8: {evidence.name} {phase}; log={log}", flush=True)
    with log.open("xb") as output:
        run = subprocess.run([str(project / argv[0]), *argv[1:]], cwd=project,
                             env=_environment(), stdout=output, stderr=subprocess.STDOUT)
    status.write_text(str(run.returncode) + "\n")
    commands.append(dict(phase=phase, argv=list(argv), status=run.returncode,
                         log=log.name, log_sha256=sha(regular(log)), status_file=status.name))
    if run.returncode:
        raise ValueError(f"{phase} exited {run.returncode}; inspect {log} and correct the failed phase before retrying")


def _verified_log(evidence, command):
    lines = regular(evidence / command["log"]).decode().splitlines()
    reports = [json.loads(line.removeprefix("verify: PASS ")) for line in lines if line.startswith("verify: PASS ")]
    if len(reports) != 1:
        raise ValueError("public verification command lacks its complete passing report")
    return reports[0]


def _core_identity(project):
    core = project / "Build/airdcpp-core/reproducible-release"
    private = document(core / "core-source-provenance.json")
    return dict(archive_sha256=sha(regular(core / "upstream/libairdcpp.a")),
        private_core_fingerprint=private["core_input_fingerprint"],
        private_version_authority_sha256=private["version_authority_sha256"],
        published_core_fingerprint=public_core_fingerprint(core, private))


def _finish_run(project, evidence, receipt, first_inventory, noops):
    inventory = distribution_inventory(project / "Dist")
    if inventory != first_inventory:
        raise ValueError("complete Dist inventory/content differs after repeated Core build and packaging")
    core = project / "Build/airdcpp-core/reproducible-release"
    private = document(core / "core-source-provenance.json")
    public = public_core_fingerprint(core, private)
    manifest = document(project / "Dist/metadata/manifest.json")
    if manifest["schema_version"] != 2 or manifest["components"][0]["core_input_fingerprint"] != public:
        raise ValueError("published normalized Core identity differs from validated private evidence")
    reports = [_verified_log(evidence, command) for command in receipt["commands"] if command["phase"] in ("verify", "repeat-verify")]
    archive = sha(regular(project / "Dist/lib/libairdcpp.a"))
    if len(reports) != 2 or any(report["archive_sha256"] != archive for report in reports):
        raise ValueError("fresh public verifier archive binding differs")
    receipt.update(result="PASS", authority_sha256=_authority(project),
        tool_inventory=document(core / "tool-inventory.json"),
        private_core_fingerprint=private["core_input_fingerprint"],
        private_version_authority_sha256=private["version_authority_sha256"],
        published_core_fingerprint=public, archive_sha256=archive,
        inventory_sha256=sha(canonical(inventory)), rerun_inventory_equal=True,
        acquisition_dependency_build_noops=noops, verification=reports,
        tracked_generated_paths=[], tracked_status=_git(project, "status", "--porcelain", "--untracked-files=no").decode())
    (evidence / "final-dist-inventory.json").write_bytes(canonical(inventory))
    return receipt


def _validate_receipt(path):
    path = Path(path).absolute()
    receipt = document(path)
    required = {"schema_version", "result", "project_root", "root_identity", "implementation_commit",
        "implementation_inventory_sha256", "fresh_generated_absent", "commands", "host", "authority_sha256",
        "tool_inventory", "private_core_fingerprint", "private_version_authority_sha256", "published_core_fingerprint",
        "archive_sha256", "inventory_sha256", "rerun_inventory_equal", "acquisition_dependency_build_noops",
        "verification", "tracked_generated_paths", "tracked_status", "no_op_snapshots_sha256",
        "core_archive_sha256", "core_rerun_identity_equal", "core_identity_sha256"}
    if not required.issubset(receipt) or receipt["schema_version"] != 1 or receipt["result"] != "PASS":
        raise ValueError("failed or partial clean-build receipt")
    project = Path(receipt["project_root"])
    if project != path.parent / "project" or receipt["root_identity"] != list(_identity(project)):
        raise ValueError("clean-build root identity differs")
    with OwnedDirectory(project):
        if (receipt["fresh_generated_absent"] != list(GENERATED) or receipt["tracked_generated_paths"] != []
                or receipt["tracked_status"] or receipt["rerun_inventory_equal"] is not True
                or receipt["acquisition_dependency_build_noops"] is not True
                or receipt["core_rerun_identity_equal"] is not True):
            raise ValueError("clean-start, no-op, rerun or tracked-scope evidence incomplete")
        noops = document(path.parent / "no-op-snapshots.json")
        if (sha(regular(path.parent / "no-op-snapshots.json")) != receipt["no_op_snapshots_sha256"]
                or set(noops) != {"before", "after"} or noops["before"] != noops["after"]
                or set(noops["before"]) != {"Source", "Dependencies", "Build/dependencies", "Build/prefix"}):
            raise ValueError("acquisition/dependency-build no-op snapshot binding differs")
        identity = _core_identity(project)
        if (document(path.parent / "first-core-identity.json") != identity
                or document(path.parent / "repeat-core-identity.json") != identity
                or sha(canonical(identity)) != receipt["core_identity_sha256"]
                or identity["archive_sha256"] != receipt["core_archive_sha256"]):
            raise ValueError("repeated Core archive/private/public identity differs")
        if (_git(project, "rev-parse", "HEAD").decode().strip() != receipt["implementation_commit"]
                or _implementation_inventory(project) != receipt["implementation_inventory_sha256"]
                or _authority(project) != receipt["authority_sha256"]
                or _git(project, "status", "--porcelain", "--untracked-files=no").strip()):
            raise ValueError("clean-build implementation/config authority differs")
        commands = receipt["commands"]
        if len(commands) != len(ALL_COMMANDS):
            raise ValueError("clean-build command sequence incomplete")
        for index, (command, (phase, argv)) in enumerate(zip(commands, ALL_COMMANDS), 1):
            stem = f"{index:02d}-{phase}"
            if (command["phase"] != phase or command["argv"] != list(argv) or command["status"] != 0
                    or command["log"] != stem + ".log" or command["status_file"] != stem + ".status"
                    or regular(path.parent / command["status_file"]) != b"0\n"
                    or sha(regular(path.parent / command["log"])) != command["log_sha256"]):
                raise ValueError("failed, reordered or unbound clean-build command evidence")
        inventory = distribution_inventory(project / "Dist")
        if (inventory != document(path.parent / "first-dist-inventory.json")
                or inventory != document(path.parent / "final-dist-inventory.json")
                or sha(canonical(inventory)) != receipt["inventory_sha256"]
                or sha(regular(project / "Dist/lib/libairdcpp.a")) != receipt["archive_sha256"]):
            raise ValueError("full package inventory or rerun bytes differ")
        core = project / "Build/airdcpp-core/reproducible-release"
        private = document(core / "core-source-provenance.json")
        if (public_core_fingerprint(core, private) != receipt["published_core_fingerprint"]
                or private["core_input_fingerprint"] != receipt["private_core_fingerprint"]
                or private["version_authority_sha256"] != receipt["private_version_authority_sha256"]
                or document(core / "tool-inventory.json") != receipt["tool_inventory"]):
            raise ValueError("Core private/public/tool receipt binding differs")
        reports = [_verified_log(path.parent, command) for command in commands if command["phase"] in ("verify", "repeat-verify")]
        if receipt["verification"] != reports or any(report["archive_sha256"] != receipt["archive_sha256"] for report in reports):
            raise ValueError("public verifier receipt binding differs")
    return receipt, inventory


def compare_receipts(first, second):
    left, left_inventory = _validate_receipt(first)
    right, right_inventory = _validate_receipt(second)
    if left["project_root"] == right["project_root"] or left["root_identity"] == right["root_identity"]:
        raise ValueError("two independently owned clean roots are required")
    for field in ("implementation_commit", "implementation_inventory_sha256", "authority_sha256", "host", "tool_inventory", "published_core_fingerprint", "core_archive_sha256"):
        if left[field] != right[field]:
            raise ValueError("clean-build declared input identity differs: " + field)
    if left_inventory != right_inventory:
        raise ValueError("two-clean-build complete Dist inventories/content differ")
    return dict(result="PASS", exact_full_inventory_equal=True, inventory_sha256=left["inventory_sha256"],
                archive_sha256=left["archive_sha256"], independent_roots=True)


def run_clean_builds(project):
    project = Path(project).absolute()
    with OwnedDirectory(project):
        if Path(_git(project, "rev-parse", "--show-toplevel").decode().strip()) != project:
            raise ValueError("Gate 8 requires its own Git project root")
        if _git(project, "status", "--porcelain", "--untracked-files=all").strip():
            raise ValueError("Gate 8 refuses uncommitted implementation inputs; commit reviewed changes first")
        commit = _git(project, "rev-parse", "HEAD").decode().strip()
        implementation = _implementation_inventory(project)
    host = _host()
    if host["system"] != "Darwin" or host["architecture"] != "arm64":
        raise ValueError("Gate 8 requires the declared native macOS arm64 host")
    evidence = Path(tempfile.mkdtemp(prefix="airdc-gate8-", dir="/private/tmp"))
    runs = []
    try:
        # BOTH tracked-only roots exist and attest clean start before acquisition.
        for number in (1, 2):
            directory = evidence / f"run-{number}"
            directory.mkdir()
            root = directory / "project"
            subprocess.run(["git", "-c", "core.hooksPath=/dev/null", "clone", "-q", "--no-local", "--no-hardlinks", "--no-checkout",
                            str(project), str(root)], check=True, env=_environment())
            _git(root, "checkout", "-q", "--detach", commit)
            if any((root / name).exists() or (root / name).is_symlink() for name in GENERATED):
                raise ValueError("fresh tracked-only checkout contains generated inputs")
            if _implementation_inventory(root) != implementation:
                raise ValueError("fresh checkout implementation differs from frozen commit")
            receipt = dict(schema_version=1, result="PENDING", project_root=str(root), root_identity=list(_identity(root)),
                implementation_commit=commit, implementation_inventory_sha256=implementation,
                fresh_generated_absent=list(GENERATED), host=host, commands=[])
            (directory / "receipt.json").write_bytes(canonical(receipt))
            runs.append((root, directory, receipt))
        for root, directory, receipt in runs:
            try:
                before_noops, first_inventory, first_core = None, None, None
                for phase, argv in ALL_COMMANDS:
                    if phase == "repeat-update":
                        before_noops = _noop_snapshot(root)
                    if phase in ("core", "repeat-core"):
                        (root / "Build/airdcpp-core").mkdir(parents=True, exist_ok=True)
                    _execute(root, directory, phase, argv, receipt["commands"])
                    (directory / "receipt.json").write_bytes(canonical(receipt))
                    if phase == "core":
                        first_core = _core_identity(root)
                        (directory / "first-core-identity.json").write_bytes(canonical(first_core))
                    elif phase == "repeat-core":
                        repeated_core = _core_identity(root)
                        (directory / "repeat-core-identity.json").write_bytes(canonical(repeated_core))
                        if first_core != repeated_core:
                            raise ValueError("repeated Core archive/private/public identity differs")
                        receipt.update(core_archive_sha256=repeated_core["archive_sha256"],
                            core_rerun_identity_equal=True, core_identity_sha256=sha(canonical(repeated_core)))
                    elif phase == "verify":
                        first_inventory = distribution_inventory(root / "Dist")
                        (directory / "first-dist-inventory.json").write_bytes(canonical(first_inventory))
                    if phase == "repeat-dependency-build":
                        after_noops = _noop_snapshot(root)
                        raw_noops = canonical(dict(before=before_noops, after=after_noops))
                        (directory / "no-op-snapshots.json").write_bytes(raw_noops)
                        if before_noops != after_noops:
                            raise ValueError("repeated acquisition or dependency build was not a no-op")
                        receipt["no_op_snapshots_sha256"] = sha(raw_noops)
                _finish_run(root, directory, receipt, first_inventory, True)
                (directory / "receipt.json").write_bytes(canonical(receipt))
            except Exception as error:
                receipt.update(result="FAIL", error=str(error))
                (directory / "receipt.json").write_bytes(canonical(receipt))
                raise
        comparison = compare_receipts(*(directory / "receipt.json" for root, directory, receipt in runs))
        rehearsal = rehearse_release(project)
        if _git(project, "rev-parse", "HEAD").decode().strip() != commit or _implementation_inventory(project) != implementation:
            raise ValueError("source implementation changed during the experiment")
        receipt = dict(schema_version=1, result="PASS", mode="two fresh same-host builds; disposable release rehearsal",
            implementation_commit=commit, runs=[str(directory / "receipt.json") for root, directory, run in runs],
            comparison=comparison, release_rehearsal=rehearsal,
            physical_fresh_machine_tested=False, macos14_runtime_tested=host["macos_version"].startswith("14."))
        (evidence / "receipt.json").write_bytes(canonical(receipt))
        return dict(receipt, evidence=str(evidence))
    except Exception as error:
        (evidence / "receipt.json").write_bytes(canonical(dict(schema_version=1, result="FAIL", implementation_commit=commit,
            error=str(error), runs=[str(directory / "receipt.json") for root, directory, receipt in runs])))
        raise ReleaseError(str(error), evidence) from error


def main(project, argv=None):
    parser = argparse.ArgumentParser(description="Verify public Dist with a fresh relocated network-denied consumer.")
    parser.add_argument("distribution", nargs="?", metavar="DIST")
    args = parser.parse_args(argv)
    try:
        print("verify: PASS " + json.dumps(verify_distribution(project, args.distribution), sort_keys=True))
        return 0
    except (OSError, ValueError, RuntimeError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print("verify: error: " + str(error) + "; inspect package integrity and tracked authority before retrying", file=sys.stderr)
        return 1


def gate_main(project):
    try:
        receipt = run_clean_builds(project)
        print("Gate 8 experiment: PASS " + json.dumps(receipt, sort_keys=True))
        return 0
    except (OSError, ValueError, RuntimeError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print("Gate 8 experiment: FAIL " + str(error), file=sys.stderr)
        if isinstance(error, ReleaseError):
            print("Retained evidence: " + str(error.evidence), file=sys.stderr)
        return 1
