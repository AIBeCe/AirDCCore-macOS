# AirDCCore-macOS

Build and verify an AirDC++ Core static distribution for macOS Apple Silicon.

The distribution contains public headers and one aggregate
`libairdcpp.a`, including its non-system static dependencies.
It uses C++20, Apple Clang, libc++, and Release optimization.

Intel builds, Objective-C++ wrappers, Swift Package Manager integration,
and the client application are outside this repository's scope.

## Requirements

- An Apple Silicon Mac running macOS.
- Xcode with its macOS SDK selected through `xcode-select`.
- Git, Python 3, CMake, Ninja, Perl, Make, and Apple's build tools.
- Internet access for initial source acquisition.
- Several gigabytes of free space for sources and build artifacts.

Homebrew can provide the host tools:

```sh
brew install cmake ninja python
```

Dependencies are built from locked sources, not Homebrew libraries.

The validated build host used macOS 26.5.1, macOS SDK 26.5,
Apple Clang 21.0.0, CMake 4.4.3, Ninja 1.13.2, and Python 3.14.7.
Publication checks validate the recorded compiler/tool identities.
A different toolchain may be rejected and requires separate validation.

The deployment target is macOS 14.0. This is not a claim that runtime
behavior has been tested on every macOS version since 14.0.

## Download

Clone the release:

```sh
git clone --branch v1.0.0 https://github.com/AIBeCe/AirDCCore-macOS.git
cd AirDCCore-macOS
```

Use Git clone; GitHub source ZIP/tar downloads cannot run these build scripts.
No precompiled binary download is provided by these instructions.

The release tag identifies this distribution project. The original
AirDC++ Core and dependency versions are recorded separately in
`config/upstream.env` and `config/dependencies.lock`.

## Build from source

Run these commands in order from the repository root:

```sh
./scripts/update
./scripts/update --dependencies
./scripts/build --build-dependencies
mkdir -p Build/airdcpp-core
./scripts/build --build-reproducible-core
./scripts/build --link-reproducible-consumer
./scripts/package
./scripts/verify
```

No Git submodules are required. Acquisition validates the locked inputs.
Builds use private staging directories without modifying original sources.

The private consumer step must run before packaging creates `Dist`.
The final verification independently checks the packaged distribution
and compiles, links, and runs a relocated C++ consumer.

## Output

```text
Dist/
├── include/       Public Core and dependency headers
├── lib/
│   └── libairdcpp.a
├── licenses/      License texts and notices
└── metadata/      Manifests, checksums, provenance, and link interface
```

`Dist/lib/libairdcpp.a` is a thin ARM64 archive, not a universal binary.
It aggregates Core and the required non-system static archives.

SDK Iconv remains an explicit link dependency. libc++ and libSystem
remain system dependencies; no Apple frameworks are required.

## Using the library

Compile consumers with C++20, libc++, ARM64, a macOS deployment target
of 14.0 or later, and `NO_CLIENT_UPDATER` defined.

Add these include directories:

```text
Dist/include
Dist/include/airdcpp
```

Link `Dist/lib/libairdcpp.a` and SDK Iconv (`-liconv`).
See `Dist/metadata/link-interface.json` for the packaged link contract.

Some Core headers require their normal parent/header context.
The public verifier checks those contexts and force-loads the archive
to verify its complete link closure.

OpenSSL configuration, certificates, and provider paths are runtime
integration concerns. The build uses stable upstream defaults rather
than temporary build paths; applications may override them.
These runtime resources are not supplied automatically.

## Verify or rebuild

Verify an existing distribution:

```sh
./scripts/verify
```

For a full rebuild, first run:

```sh
./scripts/clean
```

This removes validated generated `Build` and `Dist` directories,
including their build evidence. It retains downloaded sources.
Then repeat the build commands above.

Scripts reject unsafe paths, dirty source checkouts, incorrect pins,
and invalid evidence. Do not bypass these checks to publish an artifact.

## Project structure

- `Source/airdcpp-core`: downloaded, pinned original Core source.
- `Dependencies`: downloaded, locked dependency sources.
- `Build`: generated builds, static prefixes, and verification evidence.
- `Dist`: generated distribution.
- `config`: tracked pins and build/publication policies.
- `cmake`: tracked CMake integration.
- `scripts`: acquisition, build, packaging, cleanup, and verification.
- `tests` and `smoke-test`: regression and real-consumer checks.
- `docs`: architecture, decisions, operational guides, and gate reports.

Downloaded and generated directories are ignored by Git.

## Documentation

- [Build and release](docs/build-and-release.md)
- [Dependencies](docs/dependencies.md)
- [Architecture](docs/architecture.md)
- [Upstream policy](docs/upstream-policy.md)

## Licensing

AirDC++ Core carries GPL-3.0-or-later notices. Dependencies have their
own licenses. Review the packaged license texts, notices, and provenance
before redistributing or incorporating the library into an application.

The tracked GPL text is available at [licenses/GPL-3.0.txt](licenses/GPL-3.0.txt).
