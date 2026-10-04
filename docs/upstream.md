# Source acquisition

`scripts/update` has two forms. With no arguments it acquires or validates the exact detached AirDC++ Core commit in `config/upstream.env` under ignored `Source/airdcpp-core`. With `--dependencies` it validates canonical `config/dependencies.lock`, including tracked patch hashes, and reconstructs eight inputs under ignored `Dependencies/<name>`. Dependency acquisition does not configure, compile, or write `Build`/`Dist`.

```sh
./scripts/update
./scripts/update --dependencies
./scripts/update --dependencies --offline
```

Archive bytes are checked against locked SHA-256 values; Git sources are checked against full commits, origins, and canonical tree manifests. Source notices are required. File mtimes use locked `source_date_epoch`; source trees remain immutable. Symlinks, wrong origins, dirty/foreign trees, noncanonical locks, and checksum/tree drift fail before reuse. Correct sources/caches make repeated update an unchanged offline no-op.

Verified downloads live in `Dependencies/.downloads`; archive names bind component/version/checksum, and Git bundles bind commits. `--offline` fails on missing or corrupt input without contacting the network. Do not replace a checksum or edit extracted source to bypass a failure. Adapters apply reviewed tracked patches only to private build copies.

Reproducible Core likewise uses a manifest-verified private tracked-file stage, not the original checkout. Its separately tracked policy binds one exact three-file patch, deterministic pinned-epoch/count-zero version generation, and staged-header provenance. Failed original generated `version.inc` bytes remain forensic evidence; they must not be guessed or restored to make historical contracts pass.

The acquisition gate requires `Dependencies`, `Build`, and `Dist` initially absent:

```sh
AIRDCCORE_RUN_DEPENDENCY_NETWORK_TESTS=1 ./tests/gate6_dependency_acquisition_test.sh
```

It verifies online acquisition, safe removal of validated sources, exact offline reconstruction from retained caches, and unchanged repeated offline update. Use a separate fresh tracked-only checkout to preserve active build evidence. Retain normalized source/cache evidence for Gate 6. Acquisition does not authorize packaging or publishing.
