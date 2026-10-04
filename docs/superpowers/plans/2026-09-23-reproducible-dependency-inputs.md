# Reproducible Dependency Inputs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reconstruct every non-system AirDC++ Core dependency from immutable upstream source, build isolated static ARM64 prefixes, and prove that Core plus its real external consumer no longer use Homebrew libraries.

**Architecture:** A canonical JSON lock is the only dependency authority. A Python acquisition layer validates identities and extracts sources safely; a Python build orchestrator invokes small component adapters and atomically publishes validated per-component prefixes. Separate reproducible Core and consumer commands reuse the existing CMake wrapper and Gate 4 experiment while enforcing a strict prefix allowlist and retaining all raw evidence below `Build`.

**Tech Stack:** Python 3 standard library, POSIX shell, CMake/Ninja, Apple Clang/libc++, Apple archive tools, Git, curl, Make, Perl, Boost.Build, `unittest`.

**Spec:** `docs/superpowers/specs/2026-09-23-reproducible-dependency-inputs-design.md`

## Global Constraints

- Work only on `feature/reproducible-dependencies`; do not merge to `develop` until Gate 6 and whole-branch review pass.
- Target only macOS Apple Silicon: `arm64`, deployment target `14.0`, `Release`, Apple Clang, libc++, static linkage, C++20 for Core.
- Preserve Core commit `55d51ceb817ec006d4ec844d9e3788e1b0ccc352` and the existing Gate 2–5 evidence; Phase 6 uses separate build/evidence paths.
- Use no Git submodules. `Dependencies`, verified caches, build trees, prefixes, and raw evidence remain ignored and reconstructable.
- Homebrew may provide host executables only. Reproducible compile/link inputs may come only from locked component prefixes or the selected Apple SDK/toolchain.
- Keep component prefixes isolated at `Build/prefix/<name>`; do not create a merged prefix, aggregate archive, or `Dist`.
- Preserve every failed attempt before retry. Publish source trees and accepted prefixes only through validated atomic rename.
- Shell never evaluates or sources lock content. Python validates JSON and passes explicit argument vectors to component adapters.
- Any new physical dependency, Boost archive, Apple framework, or other system input blocks Gate 6 until ADR 0001 is reviewed.
- All generated paths must be real in-root paths, never symlinks; reject traversal, unsafe archive members, case-fold collisions, and source/output drift.

## Review Focus

**Execution record:** Tasks 1–11 are complete. Preserved task reports/ledger record their actual RED/GREEN history and later native corrections; the checkboxes below summarize completion rather than claim the initial proposed lock/commands stayed unchanged. Post-review code checkpoint `8bb5768` passed fresh online/offline/no-op acquisition and genuine confined all-eight/native Core/consumer checks. Final full Gate 6 at `e17ab2d` completed actual exit zero, and whole-branch integration review is PASS. Local no-fast-forward integration into `develop` and exact merge-result reverification passed. Phase 6 is finished; Phase 7 has not started.

- Archive paths that differ only by Unicode spelling or case must be rejected before extraction; Task 2 pins case-fold and NFC collision tests.
- A cache or destination swapped to a symlink between validation and publication must fail without touching the outside target; Task 2 pins race-wrapper tests.
- An interrupted or failed component rebuild must leave the prior accepted prefix byte-for-byte unchanged and retain the failed evidence; Task 3 pins publication-failure tests.
- CMake package registries, ambient `PKG_CONFIG_PATH`, or `/opt/homebrew` transitive metadata must not bypass the prefix allowlist; Task 8 pins poisoned-environment tests.
- Link ordering or imported-target changes that reintroduce Boost or a new system/framework input must block acceptance instead of silently updating the contract; Task 9 pins closure-drift tests.

---

### Task 1: Canonical dependency lock and validator

**Files:**
- Create: `config/dependencies.lock`
- Create: `scripts/lib/dependency_lock.py`
- Create: `tests/dependency_lock_test.py`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: no Phase 6 code; uses only Python 3 standard-library JSON, hashing, path, and dataclass support.
- Produces: `load_lock(path: Path) -> DependencyLock`, `canonical_bytes(lock: DependencyLock) -> bytes`, `topological_records(lock: DependencyLock) -> tuple[DependencyRecord, ...]`, and CLI commands `validate`, `record`, and `fingerprint`.
- `record --name NAME --field FIELD` prints exactly one scalar or one JSON array and never emits shell syntax.

- [x] **Step 1: Write lock validation tests that fail before the helper exists.**

  Create `tests/dependency_lock_test.py` with `unittest` cases for the accepted tracked lock and for duplicate keys, non-canonical bytes, schema versions other than `1`, unknown fields, duplicate names, invalid roles, malformed SHA-256 values, non-HTTPS archive URLs, non-full Git commits, undeclared dependencies, cycles, unsafe adapter names/options, unknown substitution tokens, invalid expected paths, and a patch whose tracked SHA-256 differs. Include this exact duplicate-key case:

  ```python
  def test_duplicate_json_key_is_rejected(self):
      result = self.validate_bytes(b'{"schema_version":1,"schema_version":1,"dependencies":[]}\n')
      self.assertNotEqual(result.returncode, 0)
      self.assertIn("duplicate JSON key: schema_version", result.stderr)
  ```

- [x] **Step 2: Run RED.**

  Run: `rtk python3 tests/dependency_lock_test.py`

  Expected: FAIL because `scripts/lib/dependency_lock.py` and `config/dependencies.lock` do not exist.

- [x] **Step 3: Implement strict typed parsing and canonical serialization.**

  Define immutable records and duplicate-key rejection in `scripts/lib/dependency_lock.py`:

  ```python
  @dataclass(frozen=True)
  class Source:
      kind: Literal["archive", "git"]
      url: str
      archive_sha256: str | None
      commit: str | None
      tag: str | None
      tree_manifest_sha256: str

  @dataclass(frozen=True)
  class DependencyRecord:
      name: str
      version: str
      role: Literal["aggregate", "build-only"]
      source: Source
      source_date_epoch: int
      dependencies: tuple[str, ...]
      adapter: str
      configure_options: tuple[str, ...]
      build_options: tuple[str, ...]
      install_options: tuple[str, ...]
      expected_headers: tuple[str, ...]
      expected_archives: tuple[str, ...]
      expected_metadata: tuple[str, ...]
      forbidden_globs: tuple[str, ...]
      license_spdx: str
      license_paths: tuple[str, ...]
      patches: tuple[Patch, ...]

  def reject_duplicate_pairs(pairs):
      result = {}
      for key, value in pairs:
          if key in result:
              raise LockError(f"duplicate JSON key: {key}")
          result[key] = value
      return result

  def canonical_json(value: object) -> bytes:
      return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")
  ```

  Permit substitutions only for `@SOURCE@`, `@BUILD@`, `@STAGE@`, `@JOBS@`, `@EPOCH@`, `@PREFIX:snappy@`, and `@SDKROOT@`. Reject NUL, newline, shell metacharacter fields, absolute expected-output paths, and `..` path components. Require dependency records to already be in topological order as well as cycle-free.

- [x] **Step 4: Add the exact canonical lock.**

  Serialize schema version `1` and these records in this exact order. Archive `tree_manifest_sha256` values use canonical UTF-8 JSON-lines entries sorted by UTF-8 path bytes: directory `{path,type}`, file `{executable,path,sha256,type}`, and symlink `{path,target,type}`. Git tree values hash the exact `git ls-tree -r --full-tree <commit>` bytes.

  | Name | Role | URL / commit | Archive SHA-256 | Tree SHA-256 | Epoch | License |
  | --- | --- | --- | --- | --- | ---: | --- |
  | `bzip2` 1.0.8 | aggregate | `https://sourceware.org/pub/bzip2/bzip2-1.0.8.tar.gz` | `ab5a03176ee106d3f0fa90e381da478ddae405918153cca248e682cd0c4a2269` | `86666cea8ea058249d1f8790280f707036eafad34eb3068861956133e037d110` | 1563040227 | `bzip2-1.0.6`, `LICENSE` |
  | `zlib` 1.3.2 | aggregate | `https://zlib.net/fossils/zlib-1.3.2.tar.gz` | `bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16` | `1ac778a242bcc68a9357cc496886ce7f25604fd47d4255b4a2049635a5c73fdd` | 1771332426 | `Zlib`, `LICENSE` |
  | `openssl` 3.5.8 | aggregate | `https://github.com/openssl/openssl/releases/download/openssl-3.5.8/openssl-3.5.8.tar.gz` | `a8f84a39918ec6415ce765d9b429d313ba97b8143169c172e734b9514464f5b2` | `874f5ab3a628fc7671f81bb76727953f6b841a1cd52cb21c1738c586a01fa238` | 1787658999 | `Apache-2.0`, `LICENSE.txt` |
  | `miniupnpc` 2.3.3 | aggregate | `https://www.miniupnp.tuxfamily.org/files/miniupnpc-2.3.3.tar.gz` | `d52a0afa614ad6c088cc9ddff1ae7d29c8c595ac5fdd321170a05f41e634bd1a` | `1c88113661511864029209d4334cb4eeb28d596d14704fb364a6f849e051917b` | 1748300157 | `BSD-3-Clause`, `LICENSE` |
  | `libmaxminddb` 1.13.3 | aggregate | `https://github.com/maxmind/libmaxminddb/releases/download/1.13.3/libmaxminddb-1.13.3.tar.gz` | `a66502ea76eadbe17f2cd6fd708946777253972d2ae8157dee1b23a2fb528171` | `6e6edb06535e089c0698fce07249a3ab3bd685d2a98ee475a389af618cde2b65` | 1772732732 | `Apache-2.0`, `LICENSE` |
  | `snappy` 1.2.2 | aggregate | `https://github.com/google/snappy.git`, commit `6af9287fbdb913f0794d0148c6aa43b58e63c8e3`, tag `1.2.2` | absent | `6e3dda3fa8c40bdc79d77fe2f68e4c5d7b703387367bbcda7fe12131849ceb18` | 1743002362 | `BSD-3-Clause`, `COPYING` |
  | `leveldb` 1.23 | aggregate | `https://github.com/google/leveldb.git`, commit `99b3c03b3284f5886f9ef9a4ef703d57373e61be`, tag `1.23` | absent | `b91ddef6557cac0d83ac0938f6ef3f4d70effa9eed32f2691950fd6d103a0c0d` | 1614113677 | `BSD-3-Clause`, `LICENSE` |
  | `boost` 1.90.0 | build-only | `https://archives.boost.io/release/1.90.0/source/boost_1_90_0.tar.bz2` | `49551aff3b22cbc5c5a9ed3dbc92f0e23ea50a0f7325b0d198b705e8ee3fc305` | `3b5de250b4466b2c655e1b2e00c9d0fa43bd33d4cb219f9bc2bec412d8bc27e2` | 1764771748 | `BSL-1.0`, `LICENSE_1_0.txt` |

  Record dependencies as `leveldb -> [snappy]` and all others as empty. Initially record patches as empty arrays; the approved native Boost relocation correction later adds its exact tracked build-copy patch/hash, while other dependency patch arrays remain empty. Set every platform contract to architecture `arm64`, deployment target `14.0`, build type `Release`, C++ runtime `libc++`, and linkage `static`.

- [x] **Step 5: Record complete ordered adapter options and outputs.**

  Use the following lock content; token replacement is performed as argument substitution, never through a shell:

  - `bzip2`: adapter `bzip2`; build `CC=/usr/bin/clang`, `AR=/usr/bin/ar`, `RANLIB=/usr/bin/ranlib`, `CFLAGS=-O3 -DNDEBUG -D_FILE_OFFSET_BITS=64 -arch arm64 -mmacosx-version-min=14.0`; headers `include/bzlib.h`; archive `lib/libbz2.a`; no package metadata.
  - `zlib`: adapter `cmake`; configure `-G`, `Ninja`, `-DCMAKE_BUILD_TYPE=Release`, `-DZLIB_BUILD_SHARED=OFF`, `-DZLIB_BUILD_STATIC=ON`, `-DZLIB_BUILD_TESTING=ON`, `-DCMAKE_OSX_ARCHITECTURES=arm64`, `-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0`, `-DCMAKE_INSTALL_PREFIX=@STAGE@`; header `include/zlib.h`; archive `lib/libz.a`; metadata `lib/cmake/ZLIB/ZLIBConfig.cmake`, `lib/pkgconfig/zlib.pc`.
  - `openssl`: adapter `openssl`; configure `darwin64-arm64-cc`, `no-shared`, `no-pinshared`, `--prefix=@STAGE@`, `--openssldir=@STAGE@/ssl`, `-arch`, `arm64`, `-mmacosx-version-min=14.0`; build `-j@JOBS@`; install `install_dev`; headers `include/openssl/ssl.h`, `include/openssl/crypto.h`; archives `lib/libssl.a`, `lib/libcrypto.a`; metadata `lib/pkgconfig/openssl.pc`.
  - `miniupnpc`: adapter `cmake`; configure common CMake flags plus `-DUPNPC_BUILD_STATIC=ON`, `-DUPNPC_BUILD_SHARED=OFF`, `-DUPNPC_BUILD_TESTS=ON`, `-DUPNPC_BUILD_SAMPLE=OFF`; header `include/miniupnpc/miniupnpc.h`; archive `lib/libminiupnpc.a`; metadata `lib/cmake/miniupnpc/miniupnpc-config.cmake`, `lib/pkgconfig/miniupnpc.pc`.
  - `libmaxminddb`: adapter `cmake`; configure common CMake flags plus `-DBUILD_SHARED_LIBS=OFF`, `-DBUILD_TESTING=ON`, `-DMAXMINDDB_BUILD_BINARIES=OFF`, `-DMAXMINDDB_INSTALL=ON`; header `include/maxminddb.h`; archive `lib/libmaxminddb.a`; metadata `lib/cmake/maxminddb/maxminddb-config.cmake`, `lib/pkgconfig/libmaxminddb.pc`.
  - `snappy`: adapter `cmake`; configure common CMake flags plus `-DBUILD_SHARED_LIBS=OFF`, `-DSNAPPY_BUILD_TESTS=OFF`, `-DSNAPPY_BUILD_BENCHMARKS=OFF`, `-DSNAPPY_FUZZING_BUILD=OFF`, `-DSNAPPY_INSTALL=ON`; header `include/snappy.h`; archive `lib/libsnappy.a`; metadata `lib/cmake/Snappy/SnappyConfig.cmake`.
  - `leveldb`: adapter `cmake`; configure common CMake flags plus `-DBUILD_SHARED_LIBS=OFF`, `-DLEVELDB_BUILD_TESTS=OFF`, `-DLEVELDB_BUILD_BENCHMARKS=OFF`, `-DLEVELDB_INSTALL=ON`, `-DCMAKE_PREFIX_PATH=@PREFIX:snappy@`; header `include/leveldb/db.h`; archive `lib/libleveldb.a`; metadata `lib/cmake/leveldb/leveldbConfig.cmake`.
  - `boost`: adapter `boost`; configure `--prefix=@STAGE@`, `--with-libraries=regex,thread`; build `variant=release`, `link=static`, `runtime-link=shared`, `threading=multi`, `address-model=64`, `architecture=arm`, `cxxflags=-arch arm64 -mmacosx-version-min=14.0 -O3 -DNDEBUG`, `linkflags=-arch arm64 -mmacosx-version-min=14.0`, `--layout=system`, `-j@JOBS@`; headers `include/boost/regex.hpp`, `include/boost/thread.hpp`; archives `lib/libboost_regex.a`, `lib/libboost_thread.a`; metadata `lib/cmake/Boost-1.90.0/BoostConfig.cmake`.

  Every record forbids `**/*.dylib`, `**/*.so`, `**/*.so.*`, and `**/*.la`.

- [x] **Step 6: Ignore reconstructed data without broadening tracked-source exclusions.**

  Add only `/Dependencies/` to `.gitignore`; retain the existing `/Build/` and `/Dist/` rules and do not ignore lock files, patches, reports, or tests.

- [x] **Step 7: Run GREEN and canonical-byte checks.**

  Run:

  ```sh
  rtk python3 tests/dependency_lock_test.py
  rtk python3 scripts/lib/dependency_lock.py validate --lock config/dependencies.lock
  rtk git diff --check
  ```

  Expected: tests print `OK`, validation prints the lock fingerprint, and `git diff --check` is silent.

- [x] **Step 8: Commit checkpoint 1A.**

  ```sh
  rtk git add .gitignore config/dependencies.lock scripts/lib/dependency_lock.py tests/dependency_lock_test.py
  rtk git commit -m "feat: lock reproducible dependency inputs"
  ```

### Task 2: Safe, idempotent dependency acquisition

**Files:**
- Create: `scripts/lib/dependency_acquire.py`
- Create: `scripts/lib/update_core.sh`
- Create: `tests/dependency_acquisition_test.py`
- Create: `tests/gate6_dependency_acquisition_test.sh`
- Modify: `scripts/update`

**Interfaces:**
- Consumes: Task 1 `DependencyLock`, `DependencyRecord`, `load_lock`, `topological_records`, and canonical fingerprinting.
- Produces: `acquire_all(project_root: Path, lock: DependencyLock, offline: bool) -> None`, `inspect_archive(archive: Path, record: DependencyRecord) -> ArchivePlan`, `tree_manifest(root: Path) -> bytes`, and `scripts/update --dependencies [--offline]`.
- Accepted paths: cache `Dependencies/.downloads/<name>-<version>-<sha12>.<suffix>` and source `Dependencies/<name>`.

- [x] **Step 1: Write failing acquisition safety tests.**

  Generate tiny tar, tar.gz, tar.bz2, and local Git fixtures inside each test temporary directory. Test checksum-before-open ordering, absolute/traversal names, duplicate normalized names, regular-file/directory aliasing, device/FIFO entries, escaping hard/symbolic links, two top-level roots, case-fold collisions, NFC-equivalent names, file-count limits, license absence, source-tree hash mismatch, Git wrong commit, Git dirty/untracked content, interrupted downloads, offline cache reuse, idempotent no-op, and drift refusal.

  Add a race test that replaces `.downloads` or the destination with a symlink immediately before `os.replace`; assert the outside marker remains unchanged and stderr contains `path identity changed before publication`.

- [x] **Step 2: Run RED.**

  Run: `rtk python3 tests/dependency_acquisition_test.py`

  Expected: FAIL because the acquisition module and update mode do not exist.

- [x] **Step 3: Implement path ownership and safe archive inspection.**

  In `dependency_acquire.py`, open project-controlled directories with `lstat`, store `(st_dev, st_ino)`, and recheck immediately before every rename. Parse tar members before extraction and materialize entries yourself rather than calling `tar`:

  ```python
  def normalize_member(name: str) -> PurePosixPath:
      path = PurePosixPath(name)
      if not name or name.startswith("/") or "\x00" in name or ".." in path.parts:
          raise AcquireError(f"unsafe archive member: {name!r}")
      normalized = PurePosixPath(*part for part in path.parts if part not in ("", "."))
      if not normalized.parts:
          raise AcquireError(f"empty archive member: {name!r}")
      return normalized
  ```

  Reject non-regular/directory/symlink/hard-link types, normalized duplicates, `casefold()` or NFC collisions, unsafe link targets, and more than 100,000 members. Extract into `Dependencies/.staging-<random>`, strip the single declared top-level directory, normalize staging mtimes to `source_date_epoch`; require published regular-file and symlink mtimes to retain that epoch; populated-directory mtimes may reflect native publication. Compute the canonical tree manifest before publication.

- [x] **Step 4: Implement checksum-verified archive download and offline reuse.**

  Stream HTTPS bytes through SHA-256 into a cache sibling temporary file, `fsync` it, compare the exact digest, and atomically rename it. Never send credentials or inherit proxy values into evidence. If a correct cache exists, do not access the network. In `--offline` mode, report every missing cache in lock order and perform no partial extraction.

- [x] **Step 5: Implement immutable Git acquisition without submodules.**

  Initialize a temporary repository, set the exact origin, fetch only the full pinned commit, detach it, disable recursive submodules, and verify both commit and `git ls-tree -r --full-tree` hash. Reject any checked-out gitlink whose path is needed by the adapter; Snappy and LevelDB tests/benchmarks stay disabled, so their declared gitlinks remain uninitialized and excluded from the published filesystem tree. Reject tracked, staged, untracked, and initialized-submodule drift on reuse.

- [x] **Step 6: Add the update entry point without changing no-argument behavior.**

  Parse only these forms in `scripts/update`:

  ```sh
  case "$#:$*" in
    0:) exec /bin/sh "$PROJECT_ROOT/scripts/lib/update_core.sh" "$PROJECT_ROOT" ;;
    1:--dependencies) exec python3 "$PROJECT_ROOT/scripts/lib/dependency_acquire.py" --project-root "$PROJECT_ROOT" ;;
    2:--dependencies\ --offline) exec python3 "$PROJECT_ROOT/scripts/lib/dependency_acquire.py" --project-root "$PROJECT_ROOT" --offline ;;
    *) printf 'usage: scripts/update [--dependencies [--offline]]\n' >&2; exit 64 ;;
  esac
  ```

  Move the existing no-argument body verbatim to `scripts/lib/update_core.sh` and keep its arguments, diagnostics, and exit statuses unchanged.

- [x] **Step 7: Add the opt-in live acquisition gate.**

  `tests/gate6_dependency_acquisition_test.sh` must skip unless `AIRDCCORE_RUN_DEPENDENCY_NETWORK_TESTS=1`, require an initially absent real `Dependencies`, run online acquisition, capture source/cache fingerprints, remove only validated extracted component directories, run `scripts/update --dependencies --offline`, and compare source/cache fingerprints, regular-file and symlink mtimes, and cache mtimes across online and offline reconstruction. Then run offline acquisition again and require the complete filesystem snapshot, including every directory and `.git` metadata, to remain unchanged. It must verify licenses, exact commits/checksums/tree manifests, absence of `Build`/`Dist`, and `git ls-files Dependencies Build Dist` is empty.

- [x] **Step 8: Run GREEN and the Phase 1 regression for update.**

  ```sh
  rtk python3 tests/dependency_acquisition_test.py
  rtk ./tests/update_test.sh
  rtk python3 tests/dependency_lock_test.py
  rtk git diff --check
  ```

  Expected: all pass without network.

- [x] **Step 9: Commit checkpoint 1B.**

  ```sh
  rtk git add scripts/update scripts/lib/update_core.sh scripts/lib/dependency_acquire.py tests/dependency_acquisition_test.py tests/gate6_dependency_acquisition_test.sh
  rtk git commit -m "feat: acquire locked dependency sources safely"
  ```

### Task 3: Build orchestration, evidence retention, and prefix validation

**Files:**
- Create: `scripts/lib/dependency_build.py`
- Create: `scripts/lib/dependency_prefix.py`
- Create: `tests/dependency_build_orchestration_test.py`
- Modify: `scripts/build`

**Interfaces:**
- Consumes: Task 1 lock records and Task 2 accepted sources.
- Produces: `build_all(project_root: Path, lock: DependencyLock) -> None`, `validate_prefix(record, prefix, allowed_roots) -> PrefixReport`, `scripts/build --build-dependencies`, and adapter process contract `adapter SOURCE BUILD STAGE JOBS EPOCH [DEPENDENCY_PREFIX ...]`.
- Evidence root: `Build/dependencies/<name>/evidence`; accepted prefix: `Build/prefix/<name>`.

- [x] **Step 1: Write failing orchestration and validator tests.**

  Use fake adapters and tiny real ARM64 archives to test topological order, exact argv/token expansion, allowlisted environment, no-op fingerprint reuse, failed evidence preservation, sequential `attempts/0001`, atomic prefix replacement, prior-prefix preservation on failure, cross-prefix writes, forbidden shared output, missing expected output, unsafe links, foreign/non-archive files, wrong architecture, source/home/Homebrew string leakage, malformed package metadata, and a symlink-swap publication race.

- [x] **Step 2: Run RED.**

  Run: `rtk python3 tests/dependency_build_orchestration_test.py`

  Expected: FAIL because the orchestrator and prefix validator do not exist.

- [x] **Step 3: Implement deterministic orchestration and adapter invocation.**

  Build one record at a time in lock order. Expand lock tokens as array elements, never as shell text. Supply only `PATH`, `HOME` set to an empty private build directory, `TMPDIR` below the component build root, `SOURCE_DATE_EPOCH`, `ZERO_AR_DATE=1`, `SDKROOT`, `MACOSX_DEPLOYMENT_TARGET=14.0`, `CC`, `CXX`, `AR`, `RANLIB`, and locale `LC_ALL=C`/`LANG=C`. Resolve Apple tools with `xcrun --find` before the build; host CMake/Ninja/Perl/Make paths may be Homebrew and must be inventoried.

  ```python
  ADAPTER_ARGUMENTS = ("source", "build", "stage", "jobs", "epoch")

  def run_adapter(record, paths, dependency_prefixes, env):
      argv = [str(adapter_path(record.adapter)), str(paths.source), str(paths.build),
              str(paths.stage), str(job_count()), str(record.source_date_epoch)]
      argv.extend(str(dependency_prefixes[name]) for name in record.dependencies)
      subprocess.run(argv, env=env, check=True)
  ```

- [x] **Step 4: Implement attempt and acceptance fingerprints.**

  The input fingerprint hashes canonical lock bytes, source identity, adapter bytes, ordered dependency-prefix manifests, tool inventory, and SDK version. A matching accepted evidence fingerprint plus successful revalidation is a no-op. Before retry, copy every existing evidence file to the next immutable attempt directory and write `sha256.txt`; never overwrite historical evidence.

- [x] **Step 5: Implement strict component-prefix validation.**

  Require declared files; reject undeclared top-level roots, forbidden globs, absolute/escaping links, and dylibs. For every archive, use `ar -t`, extract to a private inspection directory, require each Mach-O object to report exactly `arm64` with `lipo -archs`, inventory `nm -gU`/`nm -u`, inspect build versions where present, and run `strings`. Normalize manifests to `$PREFIX`, `$SOURCE`, and `$BUILD`; reject the real project root, source/build roots, user home, `/opt/homebrew`, `/usr/local/Cellar`, and `Cellar/` in installed files and metadata.

- [x] **Step 6: Add the build entry point.**

  Extend the existing one-mode parser without changing prior modes:

  ```sh
  --build-dependencies)
    exec python3 "$PROJECT_ROOT/scripts/lib/dependency_build.py" --project-root "$PROJECT_ROOT" ;;
  ```

  Update the usage string to list the three existing modes plus the new mode.

- [x] **Step 7: Run GREEN and entry-point regressions.**

  ```sh
  rtk python3 tests/dependency_build_orchestration_test.py
  rtk ./tests/build_configure_test.sh
  rtk ./tests/build_core_test.sh
  rtk ./tests/link_consumer_test.sh
  rtk git diff --check
  ```

- [x] **Step 8: Commit checkpoint 1C.**

  ```sh
  rtk git add scripts/build scripts/lib/dependency_build.py scripts/lib/dependency_prefix.py tests/dependency_build_orchestration_test.py
  rtk git commit -m "feat: orchestrate isolated dependency builds"
  ```

### Task 4: BZip2 and zlib static adapters

**Files:**
- Create: `scripts/lib/dependencies/build_bzip2.sh`
- Create: `scripts/lib/dependencies/build_zlib.sh`
- Create: `tests/dependency_leaf_c_adapters_test.sh`

**Interfaces:**
- Consumes: Task 3 adapter argv and staging-prefix contract.
- Produces: BZip2 and zlib accepted inputs matching the Task 1 expected paths, plus installed-header external compile/link/run evidence.

- [x] **Step 1: Write failing adapter contract tests.**

  Use fixture projects and fake `make`, `cmake`, `ninja`, compiler, and archive tools. Assert exact argument order, `-arch arm64`, `-mmacosx-version-min=14.0`, static-only options, out-of-tree zlib build, BZip2 `make check`, zlib `ctest --test-dir`, declared install files, and nonzero propagation before publication.

- [x] **Step 2: Run RED.**

  Run: `rtk ./tests/dependency_leaf_c_adapters_test.sh`

  Expected: FAIL because both adapter scripts are absent.

- [x] **Step 3: Implement BZip2 without upstream install-side binaries.**

  Run `make libbz2.a` and `make check` with the lock’s exact variables. Copy only `bzlib.h`, `libbz2.a`, and `LICENSE` into the staging prefix. Compile and run a small installed-only program that compresses and decompresses `AirDCCore` with `BZ2_bzBuffToBuffCompress` and `BZ2_bzBuffToBuffDecompress`.

- [x] **Step 4: Implement zlib with CMake.**

  Configure from source into the supplied build directory with the lock arguments, build `zlibstatic`, run CTest, and install into staging. Compile and run an installed-only program that uses `compress2` and `uncompress` and links the exact staged `lib/libz.a`.

- [x] **Step 5: Run GREEN plus orchestrator tests.**

  ```sh
  rtk ./tests/dependency_leaf_c_adapters_test.sh
  rtk python3 tests/dependency_build_orchestration_test.py
  rtk git diff --check
  ```

- [x] **Step 6: Commit checkpoint 2A.**

  ```sh
  rtk git add scripts/lib/dependencies/build_bzip2.sh scripts/lib/dependencies/build_zlib.sh tests/dependency_leaf_c_adapters_test.sh
  rtk git commit -m "feat: build pinned bzip2 and zlib"
  ```

### Task 5: OpenSSL, miniupnpc, and libmaxminddb static adapters

**Files:**
- Create: `scripts/lib/dependencies/build_openssl.sh`
- Create: `scripts/lib/dependencies/build_miniupnpc.sh`
- Create: `scripts/lib/dependencies/build_libmaxminddb.sh`
- Create: `tests/dependency_leaf_network_adapters_test.sh`

**Interfaces:**
- Consumes: Task 3 adapter contract and Task 1 lock options.
- Produces: static OpenSSL SSL/Crypto, miniupnpc, and MaxMindDB component prefixes; OpenSSL evidence is explicitly version `3.5.8` and never overwrites Gate 4’s `3.6.4` evidence.

- [x] **Step 1: Write failing exact-command and installed-consumer tests.**

  Assert OpenSSL uses `perl Configure darwin64-arm64-cc`, `no-shared`, `no-pinshared`, runs `make test`, and installs with `install_dev`; miniupnpc sets static ON/shared OFF/tests ON/sample OFF; MaxMindDB sets shared OFF/tests ON/binaries OFF/install ON. Assert each adapter runs its installed-only consumer and never reads `/opt/homebrew` headers or libraries.

- [x] **Step 2: Run RED.**

  Run: `rtk ./tests/dependency_leaf_network_adapters_test.sh`

- [x] **Step 3: Implement the OpenSSL adapter.**

  Configure in a copied private source worktree because OpenSSL’s build is in-tree, while leaving `Dependencies/openssl` immutable. Apply no patch. Build with the lock’s job option, run `make test`, run `make install_dev`, and delete nothing from staging after installation. The installed-only consumer must initialize `OPENSSL_init_ssl`, create/free `SSL_CTX`, compute a SHA-256 digest through EVP, and link exact `libssl.a` then `libcrypto.a` plus Apple system libraries selected by the compiler driver.

- [x] **Step 4: Implement miniupnpc and MaxMindDB adapters.**

  Configure, build, CTest, and install with Ninja. miniupnpc’s consumer calls `miniupnpc_lib_version()` or reads the exported version symbol supported by 2.3.3 without network access. MaxMindDB’s consumer calls `MMDB_lib_version()` without requiring a GeoIP database.

- [x] **Step 5: Run GREEN and all leaf-adapter tests.**

  ```sh
  rtk ./tests/dependency_leaf_network_adapters_test.sh
  rtk ./tests/dependency_leaf_c_adapters_test.sh
  rtk python3 tests/dependency_build_orchestration_test.py
  rtk git diff --check
  ```

- [x] **Step 6: Commit checkpoint 2B.**

  ```sh
  rtk git add scripts/lib/dependencies/build_openssl.sh scripts/lib/dependencies/build_miniupnpc.sh scripts/lib/dependencies/build_libmaxminddb.sh tests/dependency_leaf_network_adapters_test.sh
  rtk git commit -m "feat: build pinned network dependencies"
  ```

### Task 6: Snappy and LevelDB dependency chain

**Files:**
- Create: `scripts/lib/dependencies/build_snappy.sh`
- Create: `scripts/lib/dependencies/build_leveldb.sh`
- Create: `tests/dependency_leveldb_chain_test.sh`

**Interfaces:**
- Consumes: Task 3 adapter contract; LevelDB receives exactly one dependency-prefix argv, the accepted Snappy prefix.
- Produces: `Snappy::snappy`, `leveldb::leveldb`, static archives, and proof that LevelDB resolves and physically uses only the locked Snappy prefix.

- [x] **Step 1: Write failing chain tests.**

  Assert Snappy is invoked before LevelDB, LevelDB refuses zero or multiple prefix arguments, `CMAKE_PREFIX_PATH` contains only the supplied Snappy prefix, test/benchmark submodules remain uninitialized, and an ambient fake `libsnappy.a` in `/opt/homebrew` or `PKG_CONFIG_PATH` is not selected. Add a consumer that opens an in-memory temporary LevelDB database with `kSnappyCompression`, writes, reads, and closes one key.

- [x] **Step 2: Run RED.**

  Run: `rtk ./tests/dependency_leveldb_chain_test.sh`

- [x] **Step 3: Implement Snappy.**

  Configure static-only with tests and benchmarks disabled because the pinned repository records but does not acquire its GoogleTest/benchmark gitlinks. Build/install with Ninja. Compile and run an installed-only round-trip using `snappy::Compress` and `snappy::Uncompress`; record this as the compensating test.

- [x] **Step 4: Implement LevelDB against the accepted Snappy prefix.**

  Configure with only `-DCMAKE_PREFIX_PATH=<snappy-prefix>` plus the locked flags; set `CMAKE_FIND_USE_PACKAGE_REGISTRY=OFF`, `CMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=OFF`, and `CMAKE_FIND_PACKAGE_NO_PACKAGE_REGISTRY=ON`. Inspect `CMakeCache.txt`, generated link commands, and installed config to require the accepted Snappy prefix and reject Homebrew. Run the installed LevelDB+Snappy consumer with exact static archive paths.

- [x] **Step 5: Run GREEN and orchestration regression.**

  ```sh
  rtk ./tests/dependency_leveldb_chain_test.sh
  rtk python3 tests/dependency_build_orchestration_test.py
  rtk git diff --check
  ```

- [x] **Step 6: Commit checkpoint 3.**

  ```sh
  rtk git add scripts/lib/dependencies/build_snappy.sh scripts/lib/dependencies/build_leveldb.sh tests/dependency_leveldb_chain_test.sh
  rtk git commit -m "feat: build pinned snappy and leveldb"
  ```

### Task 7: Boost build-only adapter

**Files:**
- Create: `scripts/lib/dependencies/build_boost.sh`
- Create: `tests/dependency_boost_adapter_test.sh`

**Interfaces:**
- Consumes: Task 3 adapter contract and Boost lock record.
- Produces: a build-only Boost 1.90.0 prefix exporting `Boost::regex` and `Boost::thread`; it does not change the aggregate inventory.

- [x] **Step 1: Write failing Boost adapter tests.**

  Assert `bootstrap.sh` receives only `--prefix` and `--with-libraries=regex,thread`; `b2` receives the locked static ARM64/deployment flags as distinct argv entries; no shared Boost library is installed; and the external test compiles, links, and runs using `find_package(Boost 1.90.0 CONFIG REQUIRED COMPONENTS regex thread)` with registries disabled.

- [x] **Step 2: Run RED.**

  Run: `rtk ./tests/dependency_boost_adapter_test.sh`

- [x] **Step 3: Implement Boost.Build isolation and installed test.**

  Copy the immutable source into the component build root, run bootstrap and `b2 install` with the locked options, and preserve `project-config.jam`, command lines, and logs. The installed-only program must exercise `boost::regex_match` and start/join one `boost::thread`; link only archives discovered under the Boost prefix and Apple system inputs.

- [x] **Step 4: Assert build-only classification.**

  Extend the prefix report with `role=build-only` and add a test that fails if Boost appears in the Gate 5 aggregate component inventory or a future distribution input list merely because this adapter exists.

- [x] **Step 5: Run GREEN.**

  ```sh
  rtk ./tests/dependency_boost_adapter_test.sh
  rtk ./tests/gate5_distribution_shape_test.sh
  rtk python3 tests/dependency_build_orchestration_test.py
  rtk git diff --check
  ```

- [x] **Step 6: Commit checkpoint 4.**

  ```sh
  rtk git add scripts/lib/dependencies/build_boost.sh tests/dependency_boost_adapter_test.sh
  rtk git commit -m "feat: build pinned boost configure inputs"
  ```

### Task 8: Controlled reproducible Core build

**Files:**
- Create: `scripts/lib/reproducible_core.sh`
- Create: `tests/reproducible_core_test.sh`
- Modify: `scripts/build`
- Modify: `CMakeLists.txt`
- Modify: `cmake/modules/AirDCCorePolicy.cmake`
- Modify: `cmake/modules/AirDCCoreLinkAdapters.cmake`

**Interfaces:**
- Consumes: all eight accepted component prefixes and existing upstream/configure/Core helpers.
- Produces: `scripts/build --build-reproducible-core`, Core archive `Build/airdcpp-core/reproducible-release/upstream/libairdcpp.a`, and normalized package-resolution evidence.
- Does not modify `Build/airdcpp-core/core-release`, Gate 2–5 evidence, `Dependencies`, or `Dist`.

**Approved native correction:** build from a manifest-verified private tracked-file source stage under the owned reproducible output; original Source remains unchanged. `core_stage.py`, `config/core-reproducible-policy.json`, and one hash-bound patch bind exactly HashStore.cpp, CMakeLists.txt, and NetworkUtil.cpp. Reject non-24-byte Tiger-tree keys and copy into their byte array; replace only the version target COMMAND; use a constant IPv6-maximum address buffer while retaining the selected inet_ntop length. Deterministic metadata uses pinned epoch 1774518197/count zero and fixed tag/application policy. Preserve strict warnings, failed native launcher/generator/HashStore/VLA evidence, original/patched/final manifests, and staged-header provenance. The consumer validates the additive read-only staging API and both actual tag/commit identities. This supersedes direct compilation from the original checkout, without warning relaxation or source edits.

- [x] **Step 1: Write failing controlled-resolution tests.**

  With fake component prefixes and fake CMake, assert exact prefix order, exact roots for BZip2/zlib/OpenSSL, registries disabled, empty user/system environment paths, SDK Iconv selection, and separate output path. Poison `CMAKE_PREFIX_PATH`, `CMAKE_FRAMEWORK_PATH`, `CMAKE_APPBUNDLE_PATH`, `PKG_CONFIG_PATH`, `CPATH`, `LIBRARY_PATH`, and CMake user registries with Homebrew-like paths; require the command to clear or override them. Feed a configure summary containing `/opt/homebrew`, `/usr/local/Cellar`, the user home, or an undeclared prefix and require refusal.

- [x] **Step 2: Run RED.**

  Run: `rtk ./tests/reproducible_core_test.sh`

- [x] **Step 3: Replace the Homebrew-specific LevelDB assertion with a provenance-aware contract.**

  In `CMakeLists.txt`, keep the historical `-Werror` removal only when the imported interface actually contains the measured Homebrew pair. For the reproducible mode, require `leveldb::leveldb` to resolve under `AIRDCCORE_LEVELDB_PREFIX`, require its interface to contain exactly one Snappy reference, repair plain `snappy` to `Snappy::snappy`, and reject every imported location/include outside the allowlist. Add a cache boolean `AIRDCCORE_REPRODUCIBLE_INPUTS` default OFF so Gate 2–5 behavior remains unchanged.

- [x] **Step 4: Add recursive imported-target resolution evidence.**

  Implement a CMake function that walks each required target’s `IMPORTED_LOCATION`, `INTERFACE_INCLUDE_DIRECTORIES`, `INTERFACE_LINK_LIBRARIES`, and configuration-specific variants, classifies generator expressions without evaluating unsafe content, and writes normalized `dependency-resolution.tsv`. Every non-system absolute path must be below exactly one declared component prefix; Apple SDK/Xcode paths are classified `apple-system`; plain linker names are rejected except the reviewed Threads/toolchain contract.

- [x] **Step 5: Implement `reproducible_core.sh`.**

  Validate all accepted prefix reports and fingerprints, validate the pinned Core checkout, resolve SDK Iconv’s real `.tbd`, and configure `Build/airdcpp-core/reproducible-release` with:

  ```text
  -DAIRDCCORE_REPRODUCIBLE_INPUTS=ON
  -DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF
  -DCMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=OFF
  -DCMAKE_FIND_PACKAGE_NO_PACKAGE_REGISTRY=ON
  -DCMAKE_PREFIX_PATH=<bzip2;zlib;openssl;miniupnpc;leveldb;libmaxminddb;snappy;boost>
  -DBZIP2_ROOT=<bzip2>
  -DZLIB_ROOT=<zlib>
  -DOPENSSL_ROOT_DIR=<openssl>
  -DIconv_INCLUDE_DIR=<SDK>/usr/include
  -DIconv_LIBRARY=<resolved SDK libiconv.tbd>
  ```

  Reuse Gate 3’s source-prefix-map and archive inspection. Record the complete command, lock fingerprint, component manifest hashes, tool inventory, CMake cache, configure summary, resolution TSV, build log/status, archive members/symbols/strings/hash, and path-leak scan. Reject any Homebrew non-system path.

  Native implementation uses the approved private source stage and exact three-file patch described above. Bind deterministic version authority and generated outputs; validate original Source identity/bytes after success or failure. Add `rtk python3 tests/core_staging_test.py` to the final regression suite.

- [x] **Step 6: Add the build mode and scope guards.**

  Extend `scripts/build` with `--build-reproducible-core`. Snapshot the whole project excluding only `Build/airdcpp-core/reproducible-release`; after success or failure require all other tracked/ignored state unchanged, including accepted dependency prefixes and historical evidence.

- [x] **Step 7: Run GREEN and earlier Core/configure regressions.**

  ```sh
  rtk ./tests/reproducible_core_test.sh
  rtk ./tests/cmake_wrapper_test.sh
  rtk ./tests/find_modules_test.sh
  rtk ./tests/build_configure_test.sh
  rtk ./tests/build_core_test.sh
  rtk ./tests/gate3_contract_test.sh
  rtk git diff --check
  ```

- [x] **Step 8: Commit checkpoint 5A.**

  ```sh
  rtk git add scripts/build scripts/lib/reproducible_core.sh tests/reproducible_core_test.sh CMakeLists.txt cmake/modules/AirDCCorePolicy.cmake cmake/modules/AirDCCoreLinkAdapters.cmake
  rtk git commit -m "feat: build core from reproducible prefixes"
  ```

### Task 9: Reproducible external consumer and closure enforcement

**Files:**
- Create: `scripts/lib/reproducible_consumer.sh`
- Create: `tests/reproducible_consumer_test.sh`
- Modify: `scripts/build`
- Modify: `scripts/lib/normalize_link_evidence.py`
- Modify: `tests/link_evidence_test.py`

**Interfaces:**
- Consumes: Task 8 Core archive/evidence, all aggregate-role prefixes, existing smoke consumer, Gate 4 omission method, and ADR 0001.
- Produces: `scripts/build --link-reproducible-consumer`, evidence at `Build/airdcpp-core/reproducible-link-interface`, and a machine-checked closure comparison.

- [x] **Step 1: Write failing link-order, runtime, and closure-drift tests.**

  Assert the full link starts with force-loaded Core and then exact static archives in this order: BZip2, zlib, OpenSSL SSL, OpenSSL Crypto, miniupnpc, LevelDB, MaxMindDB, Snappy, followed by SDK Iconv. Assert Boost is absent. Inject a Boost archive, new `.framework`, new `-l` item, reordered OpenSSL libraries, or a non-system dylib and require `link contract differs from ADR 0001`. Require the program to print one `AirDC++ Core ...` line, exit 0, and contain no prohibited path strings/load commands.

- [x] **Step 2: Run RED.**

  ```sh
  rtk ./tests/reproducible_consumer_test.sh
  rtk python3 tests/link_evidence_test.py
  ```

- [x] **Step 3: Extend normalized evidence with component identity.**

  Update the normalizer to accept `--allowed-prefix NAME=PATH` repeatedly. Emit `component:<name>` plus prefix-relative paths for locked archives, `apple-sdk` for SDK inputs, and reject unclassified absolute link inputs. Preserve the existing Gate 4 output when no allowlist is supplied.

- [x] **Step 4: Implement the separate reproducible consumer experiment.**

  Stage the reproducible Core archive and public headers in the new evidence root. Configure the existing smoke consumer with exact archive paths, registries disabled, and no Homebrew environment. Run core-only, full, omission pass 1, reduced fixed-point full, and omission pass 2 exactly as Gate 4 does. Preserve OpenSSL 3.5.8 commands/hashes/runtime separately from historical 3.6.4 evidence.

- [x] **Step 5: Enforce ADR 0001 rather than regenerating it.**

  Parse the ADR’s aggregate inventory and system-link inventory. Compare normalized physical closure byte-for-byte to the expected components/system inputs. A changed closure exits nonzero and leaves evidence for review; it must not edit the ADR or report automatically.

- [x] **Step 6: Add entry point and binary checks.**

  Extend `scripts/build` with `--link-reproducible-consumer`. Require `file`/`lipo` exact ARM64, `otool -L` only Apple SDK/toolchain load commands, pinned Core identity at runtime, source/home/Homebrew path-leak scan, and no `Dist`/aggregate output.

- [x] **Step 7: Run GREEN and Gate 4 regression.**

  ```sh
  rtk ./tests/reproducible_consumer_test.sh
  rtk python3 tests/link_evidence_test.py
  rtk ./tests/link_consumer_test.sh
  rtk ./tests/smoke_consumer_test.sh
  rtk ./tests/gate4_contract_test.sh
  rtk ./tests/gate5_distribution_shape_test.sh
  rtk git diff --check
  ```

- [x] **Step 8: Commit checkpoint 5B.**

  ```sh
  rtk git add scripts/build scripts/lib/reproducible_consumer.sh scripts/lib/normalize_link_evidence.py tests/reproducible_consumer_test.sh tests/link_evidence_test.py
  rtk git commit -m "feat: prove reproducible static link closure"
  ```

### Task 10: Gate 6 live build, normalized report, and documentation

**Files:**
- Create: `tests/gate6_dependency_build_test.sh`
- Create: `tests/gate6_contract_test.sh`
- Create: `docs/reports/2026-09-23-gate-6-reproducible-dependencies.md`
- Modify: `README.md`
- Modify: `docs/architecture.md`
- Modify: `docs/dependencies.md`
- Modify: `docs/upstream.md`
- Modify: `docs/build-and-release.md`
- Modify: `docs/superpowers/plans/2026-09-23-reproducible-dependency-inputs.md`

**Interfaces:**
- Consumes: all Task 1–9 commands and evidence plus the Phase 6 spec/ADR.
- Produces: reviewed Gate 6 acceptance report, opt-in live gate, offline contract gate, and operator documentation. The implementation plan checkboxes become an execution record.

- [x] **Step 1: Write the failing Gate 6 contract test before the report exists.**

  Require the report to name every exact version/commit/checksum, OpenSSL LTS exception, lock fingerprint, host/tool versions, prefix manifest/archive hashes, upstream/installed checks, Core archive hash, consumer runtime line, effective closure, system inputs, license paths, omissions/compensating tests, retry history, known limitations, and all twelve Gate 6 acceptance results. Assert `Dependencies`, `Build`, and `Dist` are untracked and `Dist`/aggregate remain absent.

- [x] **Step 2: Run RED.**

  Run: `rtk ./tests/gate6_contract_test.sh`

  Expected: FAIL because the report does not exist.

- [x] **Step 3: Implement the opt-in live build gate.**

  `tests/gate6_dependency_build_test.sh` skips unless `AIRDCCORE_RUN_DEPENDENCY_TESTS=1`. It must run lock validation, accepted-source validation, `scripts/build --build-dependencies`, a second no-op build with prefix fingerprint comparison, `--build-reproducible-core`, `--link-reproducible-consumer`, all prefix validators, closure comparison, Git-boundary checks, and report validation. It must fail if network is used after acquisition or if `Dist`/an aggregate appears.

  Execution decision: the complete live process tree runs under the macOS outbound-denying sandbox with localhost permitted for OpenSSL TLS tests. Deterministic socket probes fail closed. Offline `--self-test` fixtures cover descendant confinement, prefix/evidence no-op guards, report identity/ADR/twelve-criterion refusal, and generated-path boundaries. Core/consumer snapshots exclude only their own output; freeze all other project writes and keep outer logs outside the project. Fresh native checks and accepted report normal/live validation pass; final full Gate 6 completes actual exit zero at `e17ab2d` after all writers freeze.

  Review correction: matching reuse also requires a hash-bound confinement attestation for all eight dependency adapters. Missing/stale binding triggers the approved keyword-only `build_all(force_rebuild=True)` path inside the gate sandbox, preserving attempts and retaining normal drift checks. The gate observes every completed adapter before attestation, then proves two ordinary dependency-build no-ops; valid attestation is unchanged. Report checks require actual OS/SDK versions, successful required upstream commands, only approved Snappy/LevelDB GoogleTest exceptions with explicit installed-consumer compensation, and stable evidence references that exclude self-dependent scope snapshots.

- [x] **Step 4: Execute live acquisition and build gates and capture evidence.**

  ```sh
  AIRDCCORE_RUN_DEPENDENCY_NETWORK_TESTS=1 rtk ./tests/gate6_dependency_acquisition_test.sh
  AIRDCCORE_RUN_DEPENDENCY_TESTS=1 rtk ./tests/gate6_dependency_build_test.sh
  ```

  Expected: both PASS. If an unpatched upstream build fails, preserve the attempt, diagnose it, and return to the design for approval before adding a patch record; do not weaken a validator or edit source in place.

- [x] **Step 5: Write the evidence-backed Gate 6 report.**

  Copy only normalized facts from ignored evidence. Do not copy absolute worktree/home paths, raw logs, timestamps that do not describe source identity, or mutable Homebrew library paths. Mark each acceptance criterion `PASS` with its evidence-relative path and hash. Record Snappy/LevelDB’s disabled upstream GoogleTest suites and their installed-consumer compensating checks.

- [x] **Step 6: Update operator and architecture documentation.**

  Document the two update forms, three Phase 6 build modes, offline cache behavior, exact generated layout, host-tool versus library boundary, cleanup expectations, idempotent reruns, error/evidence locations, and explicit Phase 7 handoff. State clearly that Phase 6 still does not publish `Dist` or an aggregate archive.

  `docs/upstream.md` was absent and is created for the acquisition contract. The report is accepted only after refreshed native evidence and normal/live report checks pass; final whole-branch report/delta review and final full-gate rerun remain explicit integration gates.

- [x] **Step 7: Run the full offline Phase 1–6 regression suite.**

  Run each command and require zero exit. Set `HISTORICAL_CONTRACT_CHECKOUT` to a disposable current-code checkout with copied coherent historical Source/Core/link evidence, using only the exact observed historical staged version.inc bytes (hash `65c2b8b0553cdaa61b54e6ecc6e90cdba308eeeae760f24d22b2623a78a47b3c`) in its copied source. Keep the historical contracts unchanged and never restore active forensic Source or claim unavailable immediate pre-failure bytes. Set `GATE5_TRACKED_CHECKOUT` to a fresh tracked-only current-code clone with Dependencies/Build/Dist initially absent. Keep logs outside both checkouts and the active project. All other commands run in the feature worktree.

  ```sh
  rtk ./tests/upstream_config_test.sh
  rtk ./tests/update_test.sh
  rtk ./tests/configure_helpers_test.sh
  rtk ./tests/cmake_wrapper_test.sh
  rtk ./tests/find_modules_test.sh
  rtk ./tests/build_configure_test.sh
  rtk ./tests/build_core_test.sh
  rtk python3 tests/archive_inspect_test.py
  AIRDCCORE_RUN_BUILD_TESTS=1 rtk "${HISTORICAL_CONTRACT_CHECKOUT:?}/tests/gate3_contract_test.sh"
  rtk ./tests/link_adapters_test.sh
  rtk ./tests/link_consumer_test.sh
  rtk ./tests/smoke_consumer_test.sh
  rtk python3 tests/link_evidence_test.py
  AIRDCCORE_RUN_LINK_TESTS=1 rtk "${HISTORICAL_CONTRACT_CHECKOUT:?}/tests/gate4_contract_test.sh"
  rtk "${GATE5_TRACKED_CHECKOUT:?}/tests/gate5_distribution_shape_test.sh"
  rtk python3 tests/dependency_lock_test.py
  rtk python3 tests/dependency_acquisition_test.py
  rtk python3 tests/dependency_build_orchestration_test.py
  rtk ./tests/dependency_leaf_c_adapters_test.sh
  rtk ./tests/dependency_leaf_network_adapters_test.sh
  rtk ./tests/dependency_leveldb_chain_test.sh
  rtk ./tests/dependency_boost_adapter_test.sh
  rtk ./tests/reproducible_core_test.sh
  rtk python3 tests/core_staging_test.py
  rtk ./tests/reproducible_consumer_test.sh
  rtk python3 -m unittest discover -s tests -p '*_test.py'
  rtk ./tests/gate6_contract_test.sh --self-test
  rtk ./tests/gate6_contract_test.sh
  rtk ./tests/gate6_contract_test.sh --live
  rtk git diff --check
  rtk git status --short
  rtk git ls-files Source Dependencies Build Dist
  ```

  Expected: all tests PASS; `git diff --check` is silent; status lists only intended Task 10 files before commit; generated-path listing is empty.

  Final post-review run at code checkpoint `8bb5768`: complete wrapper exit 0; all ordinary component/adapter/Core/consumer tests, 189 Python tests, fourteen report/gate fixtures, normal/live accepted report guards, unchanged explicit-live historical Gate 3/4 replay and fresh tracked-only Gate 5 PASS. No production authority changed during this report/docs checkpoint. The earlier wrapper's correct historical-header refusal remains preserved separately; it is not relabeled as a successful run.

- [x] **Step 8: Mark completed plan checkboxes and commit checkpoint 6.**

  ```sh
  rtk git add README.md docs/architecture.md docs/dependencies.md docs/upstream.md docs/build-and-release.md docs/reports/2026-09-23-gate-6-reproducible-dependencies.md docs/superpowers/plans/2026-09-23-reproducible-dependency-inputs.md tests/gate6_dependency_build_test.sh tests/gate6_contract_test.sh
  rtk git commit -m "docs: accept reproducible dependency gate"
  ```

### Task 11: Independent whole-branch review and GitFlow handoff

**Current review status:** whole-branch review and Gate 6 PASS. I1/I2/I3 are resolved and independently reviewed. The approved local no-fast-forward integration into `develop` and merge-result reverification are complete. All Step 7 commands, 189 Python tests, 14 gate fixtures and report normal/live guards passed with exit zero on the exact merged tree. Nonblocking follow-ups remain deferred. Phase 6 stops here; no Phase 7 work, push or release was performed.

**Files:**
- Review only: every change from `develop...feature/reproducible-dependencies`
- Modify only when a concrete review finding requires a tested correction.

**Interfaces:**
- Consumes: the complete Phase 6 branch, accepted spec, this plan, Gate 6 report, raw ignored evidence, and all test commands.
- Produces: an independent review verdict and, after explicit user approval, a no-fast-forward GitFlow merge into `develop`. It does not start Phase 7.

- [x] **Step 1: Run a fresh spec-compliance review.**

  A reviewer with no implementation context must compare every spec section and plan task against the branch diff and evidence. The review must prioritize acquisition attacks, atomicity/idempotence, prefix isolation, Homebrew leakage, archive architecture, OpenSSL 3.5.8 recapture, closure/ADR consistency, license completeness, generated-data boundaries, and Phase 7 scope leakage.

- [x] **Step 2: Run a fresh code-quality review.**

  Inspect Python exception boundaries, subprocess argv/environment, file-descriptor/path race defenses, archive handling, shell quoting, evidence retention, CMake imported-target traversal, test realism, and error messages. Report findings by severity with exact file/line evidence. A clean review must explicitly say no findings.

- [x] **Step 3: Resolve findings test-first and rerun affected plus full gates.**

  For each valid finding, add a failing regression, make the smallest correction, run the focused test, then rerun Task 10 Step 7 and both opt-in live Gate 6 tests. Commit each coherent correction with a descriptive `fix:` message.

- [x] **Step 4: Verify branch state before integration.**

  ```sh
  rtk git status --short --branch
  rtk git log --oneline --decorate develop..HEAD
  rtk git diff --check develop...HEAD
  rtk git diff --stat develop...HEAD
  rtk git ls-files Source Dependencies Build Dist
  ```

  Expected: clean feature branch, reviewed commit series, no whitespace errors, intended Phase 6 diff only, and no generated paths tracked.

- [x] **Step 5: Stop for explicit merge approval.**

  Report Gate 6 status, exact Core and consumer artifact locations, test evidence, review verdict, commits, and remaining Phase 7 work. Do not merge, delete the branch/worktree, push, or start Phase 7 until the user explicitly approves the GitFlow integration.

  Explicit approval is already recorded: local `--no-ff` integration after Phase 6 PASS is covered by the user's merge-after-phase request and subsequent blanket approvals. No repeated approval question is required. Root coordinates the merge and merge-result reverification; preserve the feature worktree/artifacts, and do not push or start Phase 7.

- [x] **Step 6: After approval, merge according to GitFlow and reverify.**

  Switch the main checkout to `develop`, require it clean and unchanged from the reviewed base, merge with `--no-ff feature/reproducible-dependencies`, and reverify the merge result. The user's explicit local-integration approval is recorded by the coordinator; it does not permit integration before final Gate 6 and whole-branch review PASS. Preserve the feature worktree/branch and ignored native artifacts: they contain the only accepted native outputs and raw evidence. This approved preservation deviation supersedes removing the completed worktree/branch. Do not create `master`, a release branch, tag, aggregate archive, or `Dist`, and do not push or start Phase 7.

  Completion: the verified merge tree is `720d1071785f791529398add9761d15423a02edb`. Post-merge verification exited zero; its ignored Task 11 execution record retains the command logs. This final completion record changes documentation only; accepted execution inputs and native artifacts are unchanged.
