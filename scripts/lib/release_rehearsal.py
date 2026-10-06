"""Exercise first-release GitFlow only in a newly owned disposable repository."""
import io
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile

from distribution_aggregate import canonical


def _git(project, *arguments):
    return subprocess.check_output(["git", "-c", "core.hooksPath=/dev/null",
        "-c", "user.name=Release rehearsal", "-c", "user.email=rehearsal@example.invalid",
        "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false",
        "-C", str(project), *arguments], stderr=subprocess.STDOUT)


def rehearse_release(project, version="0.0.0"):
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("rehearsal version must be MAJOR.MINOR.PATCH")
    project = Path(project).absolute()
    commit = _git(project, "rev-parse", "HEAD").decode().strip()
    before = _git(project, "for-each-ref", "--format=%(refname) %(objectname)")
    archive = _git(project, "archive", "--format=tar", commit)
    evidence = Path(tempfile.mkdtemp(prefix="airdc-release-rehearsal-", dir="/private/tmp"))
    repository = evidence / "repository"
    repository.mkdir()
    try:
        _git(repository, "init", "-q", "-b", "develop")
        _git(repository, "commit", "-q", "--allow-empty", "-m", "Rehearsal develop bootstrap")
        _git(repository, "checkout", "-q", "-b", "feature/rehearsal")
        with tarfile.open(fileobj=io.BytesIO(archive)) as source:
            source.extractall(repository, filter="data")
        _git(repository, "add", ".")
        _git(repository, "commit", "-q", "-m", "Import committed feature " + commit)
        feature_tip = _git(repository, "rev-parse", "HEAD").decode().strip()
        _git(repository, "checkout", "-q", "develop")
        _git(repository, "merge", "-q", "--no-ff", "feature/rehearsal", "-m", "Rehearsal feature integration")
        release_base = _git(repository, "rev-parse", "HEAD").decode().strip()
        release = "release/" + version
        _git(repository, "checkout", "-q", "-b", release)
        (repository / ".release-rehearsal").write_text("Disposable rehearsal only; input commit " + commit + "\n")
        _git(repository, "add", ".release-rehearsal")
        _git(repository, "commit", "-q", "-m", "Rehearsal release stabilization")
        release_tip = _git(repository, "rev-parse", "HEAD").decode().strip()
        _git(repository, "branch", "master", release_tip)
        _git(repository, "checkout", "-q", "master")
        tag = "v" + version
        _git(repository, "tag", "-a", tag, "-m", "Disposable release rehearsal; no production publication")
        _git(repository, "checkout", "-q", "develop")
        _git(repository, "merge", "-q", "--no-ff", release, "-m", "Rehearsal release merge-back")
        _git(repository, "merge-base", "--is-ancestor", "master", "develop")
        _git(repository, "merge-base", "--is-ancestor", feature_tip, "develop")
        master = _git(repository, "rev-parse", "master").decode().strip()
        tagged = _git(repository, "rev-parse", tag + "^{commit}").decode().strip()
        if master != release_tip or tagged != master or _git(repository, "cat-file", "-t", tag).strip() != b"tag":
            raise ValueError("rehearsal release/master/annotated-tag identity differs")
        if before != _git(project, "for-each-ref", "--format=%(refname) %(objectname)"):
            raise ValueError("source repository refs changed during rehearsal")
        receipt = dict(schema_version=1, result="PASS", mode="disposable local rehearsal",
            repository=str(repository), implementation_commit=commit, feature_tip=feature_tip,
            release_base=release_base, release_tip=release_tip, master=master, tag=tag,
            tag_commit=tagged, develop=_git(repository, "rev-parse", "develop").decode().strip(),
            merge_back_verified=True, source_refs_unchanged=True, production_publication=False)
        (evidence / "receipt.json").write_bytes(canonical(receipt))
        return receipt
    except Exception as error:
        (evidence / "receipt.json").write_bytes(canonical(dict(schema_version=1, result="FAIL", error=str(error))))
        error.add_note("Retained release rehearsal: " + str(evidence))
        raise
