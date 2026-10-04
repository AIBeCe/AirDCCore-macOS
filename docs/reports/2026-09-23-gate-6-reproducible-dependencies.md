# Gate 6: Reproducible dependency inputs

The recorded native dependency, Core, and force-loaded consumer capture passed its executed checks and stopped only at the then-absent report. Final acceptance is pending the whole-branch findings on declared adapter options and acquisition publication races, fresh acquisition/dependency proof after their fixes, and the final full-gate rerun. The criterion records below describe the captured evidence and do not override this pending status.

The canonical lock reconstructs eight isolated static prefixes. OpenSSL 3.5.8 is the reviewed LTS exception to earlier 3.6.4 discovery. The renewed physical closure matches ADR 0001: Core, BZip2, zlib, OpenSSL SSL/Crypto, miniupnpc, LevelDB, MaxMindDB, Snappy, then SDK Iconv. Boost is build-only. libc++ and libSystem are implicit Apple inputs; no framework or non-system dylib is required.

Dependency tests run under the outbound-denying macOS sandbox with localhost permitted for OpenSSL TLS tests. A child socket must return kernel EPERM/EACCES for a literal remote address; a loopback socket must succeed. The immutable attestation binds successful execution of every adapter, the lock, exact dependency execution code, tools, commands/test logs, prefix manifests and notices. Two ordinary dependency builds leave prefixes and component evidence unchanged. Core-only execution helpers are outside that dependency authority because the current dispatch/import call graph does not execute them.

Core builds from a manifest-verified private tracked-file stage; original Source and dependency inputs remain unchanged. One reviewed hash-bound patch touches exactly HashStore.cpp, CMakeLists.txt, and NetworkUtil.cpp: require a 24-byte Tiger-tree key before copying into the byte array; replace only the version target COMMAND with fixed wrapper authority; use the constant IPv6 maximum address buffer while retaining the selected IPv4/IPv6 inet_ntop length. Strict compiler warnings remain enabled. Version metadata uses pinned commit epoch 1774518197 and declared count zero rather than wall-clock time or mutable Git history. The staged public headers, patch pre/postimages, generated outputs, Python identity, and archive are independently bound to provenance. The consumer verifies both real tag and full commit APIs and preserves the commit-based runtime line.

Retries are retained: the initial generator rewrote ignored Source while an underlying HashStore memcpy diagnostic also failed compilation; the native launcher hypothesis failed and was replaced by the narrow version COMMAND patch; the later NetworkUtil C++ VLA failure required the third patch target. Core attempts 0001 and 0002 retain failed build logs; 0003 retains a successful build before the current rerun. Failed dependency metadata, LevelDB probe/provenance and Boost relocation attempts are preserved with their original hashes. Original failed version.inc predecessor bytes were not available and are not reconstructed or mislabeled. Snappy/LevelDB GoogleTest omissions and their explicit installed-consumer compensation are recorded per component.

The approved OpenSSL runtime defaults and their observed certificate/config descendants are intentional runtime strings, not build provenance. Raw logs, host paths and ignored evidence remain private; only normalized facts and evidence-relative digests are tracked here. This report proves ingredients and consumer behavior on the recorded host. It does not publish Dist, build an aggregate, classify collisions/coalescing, establish two-clean-build byte reproducibility, or establish actual execution on macOS 14. The feature worktree and ignored artifacts are preserved for review and Phase 7 handoff.

```json
{
  "acceptance": {
    "1": {
      "evidence": [
        {
          "path": "Build/gate6/lock-validation.json",
          "sha256": "6c6a1b863fddf368a7ad64d9f0ca57f0e5d8bedc4b417b55ab4159a7034f31c3"
        }
      ],
      "result": "PASS"
    },
    "10": {
      "evidence": [
        {
          "path": "Build/dependencies/bzip2/evidence/license-inventory.json",
          "sha256": "928664b6d65d6547d9368532e1aa397bd667a61bca57bd59aac669082bae18b4"
        },
        {
          "path": "Build/dependencies/zlib/evidence/license-inventory.json",
          "sha256": "acf921d2a5cd239868a3405cccd57dcc1b2c9dc5bd01ec41d86ac96d06fdf412"
        },
        {
          "path": "Build/dependencies/openssl/evidence/license-inventory.json",
          "sha256": "d5ad6195d082818143228e40ebdd9295d8137090acd6c0eabd143d8e206de431"
        },
        {
          "path": "Build/dependencies/miniupnpc/evidence/license-inventory.json",
          "sha256": "817e6ac9ba6072f9767b3f66560db7ec7c2106fd5bb11dddf594315c7d58448b"
        },
        {
          "path": "Build/dependencies/libmaxminddb/evidence/license-inventory.json",
          "sha256": "1add06f7c310fe138e65f8a5a9599e39daf289cf02aa441f2ce72483ee7f9868"
        },
        {
          "path": "Build/dependencies/snappy/evidence/license-inventory.json",
          "sha256": "d90d82cce4d50ad8eb26b73ce0a932ac2ff634834d0456cb381344dc96d95edd"
        },
        {
          "path": "Build/dependencies/leveldb/evidence/license-inventory.json",
          "sha256": "3083b95aac0b23b7b918300ffa3f3e0bb669cfd9d0f72f497b241cd3e76b7672"
        },
        {
          "path": "Build/dependencies/boost/evidence/license-inventory.json",
          "sha256": "134f1862dc102463e7c16f43b330bfd8c81d94548c72ecab0fe59b00fc784174"
        }
      ],
      "result": "PASS"
    },
    "11": {
      "evidence": [
        {
          "path": "Build/gate6/git-boundary-validation.json",
          "sha256": "eb629ff46011c8b4718e9489a0078673589fdd3b2d87f814340ef34dddb6cb26"
        }
      ],
      "result": "PASS"
    },
    "12": {
      "evidence": [
        {
          "path": "Build/gate6/build-validation.json",
          "sha256": "0c7251607b2e574cd3de08e26b62412333a00bb35d828c55f8b426e6226a8241"
        },
        {
          "path": "Build/gate6/git-boundary-validation.json",
          "sha256": "eb629ff46011c8b4718e9489a0078673589fdd3b2d87f814340ef34dddb6cb26"
        }
      ],
      "result": "PASS"
    },
    "2": {
      "evidence": [
        {
          "path": "Build/gate6/acquisition-validation.json",
          "sha256": "ff7afe4442ebb1c7c93fa60941cac47440521c64c3f3fd61b48e776a56c40004"
        },
        {
          "path": "Build/gate6/acquisition.raw.log",
          "sha256": "5b39dda736b7356f86a3c89c7d9e0461cbeb7e653bb3f61efa41f54d314cdd7d"
        }
      ],
      "result": "PASS"
    },
    "3": {
      "evidence": [
        {
          "path": "Build/gate6/build-validation.json",
          "sha256": "0c7251607b2e574cd3de08e26b62412333a00bb35d828c55f8b426e6226a8241"
        },
        {
          "path": "Build/gate6/acquisition-validation.json",
          "sha256": "ff7afe4442ebb1c7c93fa60941cac47440521c64c3f3fd61b48e776a56c40004"
        }
      ],
      "result": "PASS"
    },
    "4": {
      "evidence": [
        {
          "path": "Build/dependencies/bzip2/evidence/prefix-report.json",
          "sha256": "a03ccffb41a4597b277ee5c84e6221926ededa6d667a6f7ac1867522a212561a"
        },
        {
          "path": "Build/dependencies/zlib/evidence/prefix-report.json",
          "sha256": "40cc50f74e52624e11e51f00024befdcb59dfb1ab13b2771ce55c5c0cf9e99c3"
        },
        {
          "path": "Build/dependencies/openssl/evidence/prefix-report.json",
          "sha256": "71707656bd595f684b846100f4ea220293d3915767aa5c63b949ac24db6dfd4c"
        },
        {
          "path": "Build/dependencies/miniupnpc/evidence/prefix-report.json",
          "sha256": "396139377b8b3999bd93307475ad71666b81c6b723edaec6d41d47747f73fb29"
        },
        {
          "path": "Build/dependencies/libmaxminddb/evidence/prefix-report.json",
          "sha256": "a9fe471c1652b2747b4a8d903ea261d9b0d8737dc14f8024605903069cfd3ddd"
        },
        {
          "path": "Build/dependencies/snappy/evidence/prefix-report.json",
          "sha256": "9e8238691bd7eae6d72aff7a7b4d67b806a0d538207c0449ac98cc491b1f8f92"
        },
        {
          "path": "Build/dependencies/leveldb/evidence/prefix-report.json",
          "sha256": "f03cc4423905ce7615e62e665ac4d82d16d4fc6788d21fc1426124721eaad0e5"
        },
        {
          "path": "Build/dependencies/boost/evidence/prefix-report.json",
          "sha256": "3512fb0cf23aeb451c1f958f76fc0fe645f43d50307b8c68542231342e1c1c58"
        }
      ],
      "result": "PASS"
    },
    "5": {
      "evidence": [
        {
          "path": "Build/gate6/dependency-confinement.json",
          "sha256": "1c1b76206d24743d4c5561f5ab2775bb81d0b273dd08cf8419070d297fc9215f"
        },
        {
          "path": "Build/dependencies/bzip2/evidence/adapter.log",
          "sha256": "4717f4587c11b25270afccbd188583b62c456a10c2a38fab3df223e3a380fa41"
        },
        {
          "path": "Build/dependencies/zlib/evidence/adapter.log",
          "sha256": "5fb14efa9c968338c1624b67a3d477867ab031114b3cae2556a73c0afc19b64e"
        },
        {
          "path": "Build/dependencies/openssl/evidence/adapter.log",
          "sha256": "b3abcecd885c0526cd7b1bc19e9db583e0cff058ab509f5195f18305e2be0a33"
        },
        {
          "path": "Build/dependencies/miniupnpc/evidence/adapter.log",
          "sha256": "4f221d70f9082955f3ec2b70f4ddb46436522fc1de21f59a6b7a77d4bd0b4829"
        },
        {
          "path": "Build/dependencies/libmaxminddb/evidence/adapter.log",
          "sha256": "9e2c38d9bfb648b104fa97091ac99620299f27c8edd6c2ce1c3abae2fcd36fbe"
        },
        {
          "path": "Build/dependencies/snappy/evidence/adapter.log",
          "sha256": "e83167e6008a92ca3728792386b9b0b9cc4d59bb113451fec1812ac89bee7e29"
        },
        {
          "path": "Build/dependencies/leveldb/evidence/adapter.log",
          "sha256": "cbe29a679d6c77f26869a3608c978dbcf3c6b774161606e99f591ff3f6606cbe"
        },
        {
          "path": "Build/dependencies/boost/evidence/adapter.log",
          "sha256": "ee16450ac322bfc1e16b438ecfeaaf32bdd057974985a1fe4ec02523873fa608"
        }
      ],
      "result": "PASS"
    },
    "6": {
      "evidence": [
        {
          "path": "Build/airdcpp-core/reproducible-release/dependency-resolution.tsv",
          "sha256": "264d3dbff30033b47f989f9fe2614f7b21e8e06c0f5ae390348c322b5cbcf1d5"
        },
        {
          "path": "Build/airdcpp-core/reproducible-release/scope-status.txt",
          "sha256": "9a271f2a916b0b6ee6cecb2426f0b3206ef074578be55d9bc94f6f3fe3ab86aa"
        }
      ],
      "result": "PASS"
    },
    "7": {
      "evidence": [
        {
          "path": "Build/airdcpp-core/reproducible-link-interface/link-interface.tsv",
          "sha256": "ef40c936ecefe48ffcabf33df8ccf0c7ef70914b1dc1580ddf0041790b69bad5"
        },
        {
          "path": "Build/airdcpp-core/reproducible-link-interface/run/stdout.txt",
          "sha256": "727ceac90574bbe5ab4ce5f8ce5a1598dad81c2c29736485efbe1cb93a30e176"
        },
        {
          "path": "Build/airdcpp-core/reproducible-link-interface/run/exit-code.txt",
          "sha256": "9a271f2a916b0b6ee6cecb2426f0b3206ef074578be55d9bc94f6f3fe3ab86aa"
        }
      ],
      "result": "PASS"
    },
    "8": {
      "evidence": [
        {
          "path": "Build/airdcpp-core/reproducible-link-interface/path-leak-scan.txt",
          "sha256": "b984107cefac1c8aea360b9b420f61585f59504311974b65fe313f104b19f1c3"
        },
        {
          "path": "Build/airdcpp-core/reproducible-link-interface/otool-load-commands.txt",
          "sha256": "3cbf919bfcdffa6306ba3fe8fe18bf29fc03f4e213e8f692d8ab001980506375"
        },
        {
          "path": "Build/airdcpp-core/reproducible-link-interface/otool-mach-o.txt",
          "sha256": "4b813b96f174f1c6f4faedbcb9c7714e122f73c96745043468ad55591d2c0ad8"
        }
      ],
      "result": "PASS"
    },
    "9": {
      "evidence": [
        {
          "path": "Build/airdcpp-core/reproducible-link-interface/adr-comparison.txt",
          "sha256": "44a74477049ea7677777a04e0b8ef2c3bcdd303f045c9375da30db92c027f7f6"
        },
        {
          "path": "Build/airdcpp-core/reproducible-link-interface/adr-expected-link-interface.tsv",
          "sha256": "ef40c936ecefe48ffcabf33df8ccf0c7ef70914b1dc1580ddf0041790b69bad5"
        }
      ],
      "result": "PASS"
    }
  },
  "consumer": {
    "evidence": {
      "path": "Build/airdcpp-core/reproducible-link-interface/consumer-sha256.txt",
      "sha256": "ba0513bd50962f37a99e4a5a3e72f1a3796a8b700586eb8164a30b2f225d5e51"
    },
    "executable_sha256": "76335f102f376a542c53ab042fece229b47d148a32615b5ca1ca3b68fceea63b",
    "runtime_line": "AirDC++ Core 55d51ceb817ec006d4ec844d9e3788e1b0ccc352"
  },
  "core": {
    "archive_sha256": "085b179a33c9298c07554f5eac2159d531cc0208af718d2d4958f86507bfec93",
    "evidence": {
      "path": "Build/airdcpp-core/reproducible-release/archive-sha256.txt",
      "sha256": "7a08b14b9b9dceb24ca473235526dbe3c9d9eb85f7224ff670995809096d1326"
    },
    "input_fingerprint": "d306a8804b78b4acd98cab66b8b9e0e2b9c680c40b2e748a019ad55b403118c6",
    "original_manifest_sha256": "95f97fcfb433b36ae303149633b3adb566568ed467018c75c71b0fa8163db5fa",
    "patch": {
      "path": "config/patches/airdcpp-core-55d51ceb-private-build.patch",
      "sha256": "a2a0454ec5c77460d99f642e8d52e2aded1efc90968b07e2b9a0f53e33874219",
      "targets": [
        {
          "path": "airdcpp/hash/HashStore.cpp",
          "postimage_sha256": "047b51dbe8a83ad303b4a93cf9ce506673faf63367b336933a8ec95cb72c7476",
          "preimage_sha256": "1802573cb2107529848cb1b0df98a9719341a440364b4c1b3180d96a8d0df88a"
        },
        {
          "path": "CMakeLists.txt",
          "postimage_sha256": "8605186a2cb71d3f1ac158c3b7208affcf1879f6259983b0559b4caf9750ad61",
          "preimage_sha256": "450f21cce9d433a4c8d50cf97200e2ca2c05313c913e54c934badb9fbfaed9af"
        },
        {
          "path": "airdcpp/util/NetworkUtil.cpp",
          "postimage_sha256": "7e47d1ab858cebfb5f27d5439a152e174b68b26a8ec3ef081cf72bf3613ee72b",
          "preimage_sha256": "b618ccd38d355ce90f6de89f95055ef432f7e2bf5a1f6be5058c3d68faf56d09"
        }
      ]
    },
    "patched_manifest_sha256": "f8a7a5a78500a72a89e4e3807f6d9a56340264b46a8633743c8d8594ac52a240",
    "provenance_evidence": {
      "path": "Build/airdcpp-core/reproducible-release/core-source-provenance.json",
      "sha256": "6b0a829ea5e11c509b09ac5d3bc0a834389f402afeaea17642a3524b4804441e"
    },
    "source_date_epoch": 1774518197,
    "staged_manifest_sha256": "0ec4e8d8da7cbf11f398fc614d1005a6145bfb7d9f7a674f3d7cd02e286b4f10",
    "version_policy": {
      "application_id": "org.airdcpp.core.macos.configure",
      "application_name": "AirDCCore-macOS",
      "commit_count": 0,
      "tag": "0.0.0"
    }
  },
  "dependencies": [
    {
      "archives": {
        "lib/libbz2.a": "4a8352ea6d43e48030cbf9a69f64319b7b1f3a89276512c7d326daa829528d00"
      },
      "installed_checks": [
        {
          "description": "Installed headers/archive compress and decompress exact bytes",
          "evidence": {
            "path": "Build/dependencies/bzip2/evidence/adapter.log",
            "sha256": "4717f4587c11b25270afccbd188583b62c456a10c2a38fab3df223e3a380fa41"
          },
          "id": "bzip2-compression-roundtrip",
          "purposes": [
            "consumer-compile",
            "consumer-run"
          ],
          "result": "PASS"
        }
      ],
      "license_paths": [
        "LICENSE"
      ],
      "license_spdx": "bzip2-1.0.6",
      "licenses": {
        "LICENSE": "c6dbbf828498be844a89eaa3b84adbab3199e342eb5cb2ed2f0d4ba7ec0f38a3"
      },
      "name": "bzip2",
      "patches": [],
      "prefix_evidence": {
        "path": "Build/dependencies/bzip2/evidence/prefix-report.json",
        "sha256": "a03ccffb41a4597b277ee5c84e6221926ededa6d667a6f7ac1867522a212561a"
      },
      "prefix_manifest_sha256": "b354b9c2688952a4c0cd32f147f29f97dba1a653d24ddaba8616f609d886ee37",
      "role": "aggregate",
      "source_date_epoch": 1563040227,
      "source_identity": "ab5a03176ee106d3f0fa90e381da478ddae405918153cca248e682cd0c4a2269",
      "source_kind": "archive",
      "source_tag": null,
      "source_tree_sha256": "86666cea8ea058249d1f8790280f707036eafad34eb3068861956133e037d110",
      "source_url": "https://sourceware.org/pub/bzip2/bzip2-1.0.8.tar.gz",
      "upstream_checks": [
        {
          "description": "Required deterministic upstream self-tests executed successfully",
          "evidence": {
            "path": "Build/dependencies/bzip2/evidence/adapter.log",
            "sha256": "4717f4587c11b25270afccbd188583b62c456a10c2a38fab3df223e3a380fa41"
          },
          "id": "upstream-self-tests",
          "purposes": [
            "test"
          ],
          "result": "PASS"
        }
      ],
      "version": "1.0.8"
    },
    {
      "archives": {
        "lib/libz.a": "c8edb356c20cf730072fd4b97a615cde3b98ca68c16e7aa8737487d490ac18a3"
      },
      "installed_checks": [
        {
          "description": "Installed headers/archive compress and decompress exact bytes",
          "evidence": {
            "path": "Build/dependencies/zlib/evidence/adapter.log",
            "sha256": "5fb14efa9c968338c1624b67a3d477867ab031114b3cae2556a73c0afc19b64e"
          },
          "id": "zlib-compression-roundtrip",
          "purposes": [
            "consumer-compile",
            "consumer-run"
          ],
          "result": "PASS"
        }
      ],
      "license_paths": [
        "LICENSE"
      ],
      "license_spdx": "Zlib",
      "licenses": {
        "LICENSE": "e32ff4e00d9d94930537635291da39e7e612703334bf6fde8c7f1686fe8a45a2"
      },
      "name": "zlib",
      "patches": [],
      "prefix_evidence": {
        "path": "Build/dependencies/zlib/evidence/prefix-report.json",
        "sha256": "40cc50f74e52624e11e51f00024befdcb59dfb1ab13b2771ce55c5c0cf9e99c3"
      },
      "prefix_manifest_sha256": "f836c79fecc6965ce7e931014467ec1299df838c3861eb1338b316e84069bb02",
      "role": "aggregate",
      "source_date_epoch": 1771332426,
      "source_identity": "bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16",
      "source_kind": "archive",
      "source_tag": null,
      "source_tree_sha256": "1ac778a242bcc68a9357cc496886ce7f25604fd47d4255b4a2049635a5c73fdd",
      "source_url": "https://zlib.net/fossils/zlib-1.3.2.tar.gz",
      "upstream_checks": [
        {
          "description": "Required deterministic upstream self-tests executed successfully",
          "evidence": {
            "path": "Build/dependencies/zlib/evidence/adapter.log",
            "sha256": "5fb14efa9c968338c1624b67a3d477867ab031114b3cae2556a73c0afc19b64e"
          },
          "id": "upstream-self-tests",
          "purposes": [
            "test"
          ],
          "result": "PASS"
        }
      ],
      "version": "1.3.2"
    },
    {
      "archives": {
        "lib/libcrypto.a": "12b32e3c375cf56e7997e117ba494e73075d59a06d7c4470320f9c7ed418a158",
        "lib/libssl.a": "0aa97f2b53d6790d24d57a9e1a5805dc9406d3f1d9d5011832e52eed9c3d8f5d"
      },
      "installed_checks": [
        {
          "description": "Installed SSL/Crypto archives create a TLS context and compute SHA-256",
          "evidence": {
            "path": "Build/dependencies/openssl/evidence/adapter.log",
            "sha256": "b3abcecd885c0526cd7b1bc19e9db583e0cff058ab509f5195f18305e2be0a33"
          },
          "id": "openssl-tls-context-and-sha256",
          "purposes": [
            "consumer-compile",
            "consumer-run"
          ],
          "result": "PASS"
        }
      ],
      "license_paths": [
        "LICENSE.txt"
      ],
      "license_spdx": "Apache-2.0",
      "licenses": {
        "LICENSE.txt": "7d5450cb2d142651b8afa315b5f238efc805dad827d91ba367d8516bc9d49e7a"
      },
      "name": "openssl",
      "patches": [],
      "prefix_evidence": {
        "path": "Build/dependencies/openssl/evidence/prefix-report.json",
        "sha256": "71707656bd595f684b846100f4ea220293d3915767aa5c63b949ac24db6dfd4c"
      },
      "prefix_manifest_sha256": "4872737f70f2138e69ab5c13dff45eda1efb8d195a5b1e71e68e7a4bdc438245",
      "role": "aggregate",
      "source_date_epoch": 1787658999,
      "source_identity": "a8f84a39918ec6415ce765d9b429d313ba97b8143169c172e734b9514464f5b2",
      "source_kind": "archive",
      "source_tag": null,
      "source_tree_sha256": "874f5ab3a628fc7671f81bb76727953f6b841a1cd52cb21c1738c586a01fa238",
      "source_url": "https://github.com/openssl/openssl/releases/download/openssl-3.5.8/openssl-3.5.8.tar.gz",
      "upstream_checks": [
        {
          "description": "Required deterministic upstream self-tests executed successfully",
          "evidence": {
            "path": "Build/dependencies/openssl/evidence/adapter.log",
            "sha256": "b3abcecd885c0526cd7b1bc19e9db583e0cff058ab509f5195f18305e2be0a33"
          },
          "id": "upstream-self-tests",
          "purposes": [
            "test"
          ],
          "result": "PASS"
        }
      ],
      "version": "3.5.8"
    },
    {
      "archives": {
        "lib/libminiupnpc.a": "2633f2c8476e3b9b7ff24b4bbfd25198bd38c8f355a2f16f0f512b8411395ac0"
      },
      "installed_checks": [
        {
          "description": "Installed headers/archive exercise the local parser/API without router or remote-network access",
          "evidence": {
            "path": "Build/dependencies/miniupnpc/evidence/adapter.log",
            "sha256": "4f221d70f9082955f3ec2b70f4ddb46436522fc1de21f59a6b7a77d4bd0b4829"
          },
          "id": "miniupnpc-parser",
          "purposes": [
            "consumer-compile",
            "consumer-run"
          ],
          "result": "PASS"
        }
      ],
      "license_paths": [
        "LICENSE"
      ],
      "license_spdx": "BSD-3-Clause",
      "licenses": {
        "LICENSE": "52bdad87d7aefe3eab35cb02426aa748510f9398a1e2d520d93bcbb18f10dd11"
      },
      "name": "miniupnpc",
      "patches": [],
      "prefix_evidence": {
        "path": "Build/dependencies/miniupnpc/evidence/prefix-report.json",
        "sha256": "396139377b8b3999bd93307475ad71666b81c6b723edaec6d41d47747f73fb29"
      },
      "prefix_manifest_sha256": "a95d9e3fc8c0fb2dfa01092243b97e8f55d080fd85dedeaec978331a3ac17201",
      "role": "aggregate",
      "source_date_epoch": 1748300157,
      "source_identity": "d52a0afa614ad6c088cc9ddff1ae7d29c8c595ac5fdd321170a05f41e634bd1a",
      "source_kind": "archive",
      "source_tag": null,
      "source_tree_sha256": "1c88113661511864029209d4334cb4eeb28d596d14704fb364a6f849e051917b",
      "source_url": "https://www.miniupnp.tuxfamily.org/files/miniupnpc-2.3.3.tar.gz",
      "upstream_checks": [
        {
          "description": "Required deterministic upstream self-tests executed successfully",
          "evidence": {
            "path": "Build/dependencies/miniupnpc/evidence/adapter.log",
            "sha256": "4f221d70f9082955f3ec2b70f4ddb46436522fc1de21f59a6b7a77d4bd0b4829"
          },
          "id": "upstream-self-tests",
          "purposes": [
            "test"
          ],
          "result": "PASS"
        }
      ],
      "version": "2.3.3"
    },
    {
      "archives": {
        "lib/libmaxminddb.a": "32c40311cba7dcca265454f3fa0b354d56282ff073090cab919618f00bb87837"
      },
      "installed_checks": [
        {
          "description": "Installed headers/archive exercise the declared local MaxMindDB API contract",
          "evidence": {
            "path": "Build/dependencies/libmaxminddb/evidence/adapter.log",
            "sha256": "9e2c38d9bfb648b104fa97091ac99620299f27c8edd6c2ce1c3abae2fcd36fbe"
          },
          "id": "maxminddb-api",
          "purposes": [
            "consumer-compile",
            "consumer-run"
          ],
          "result": "PASS"
        }
      ],
      "license_paths": [
        "LICENSE"
      ],
      "license_spdx": "Apache-2.0",
      "licenses": {
        "LICENSE": "cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30"
      },
      "name": "libmaxminddb",
      "patches": [],
      "prefix_evidence": {
        "path": "Build/dependencies/libmaxminddb/evidence/prefix-report.json",
        "sha256": "a9fe471c1652b2747b4a8d903ea261d9b0d8737dc14f8024605903069cfd3ddd"
      },
      "prefix_manifest_sha256": "5651ff1b0352e088367059fdf8b81f2f5c6b9898a02778068934702ce43dfadb",
      "role": "aggregate",
      "source_date_epoch": 1772732732,
      "source_identity": "a66502ea76eadbe17f2cd6fd708946777253972d2ae8157dee1b23a2fb528171",
      "source_kind": "archive",
      "source_tag": null,
      "source_tree_sha256": "6e6edb06535e089c0698fce07249a3ab3bd685d2a98ee475a389af618cde2b65",
      "source_url": "https://github.com/maxmind/libmaxminddb/releases/download/1.13.3/libmaxminddb-1.13.3.tar.gz",
      "upstream_checks": [
        {
          "description": "Required deterministic upstream self-tests executed successfully",
          "evidence": {
            "path": "Build/dependencies/libmaxminddb/evidence/adapter.log",
            "sha256": "9e2c38d9bfb648b104fa97091ac99620299f27c8edd6c2ce1c3abae2fcd36fbe"
          },
          "id": "upstream-self-tests",
          "purposes": [
            "test"
          ],
          "result": "PASS"
        }
      ],
      "version": "1.13.3"
    },
    {
      "archives": {
        "lib/libsnappy.a": "343cef46d6fb742ddc9f00fc52e4bf087ade1a895509ce282b5e40d9dc56076d"
      },
      "installed_checks": [
        {
          "description": "Installed Snappy CMake target resolves its accepted archive; compress/uncompress exact bytes round-trip",
          "evidence": {
            "path": "Build/dependencies/snappy/evidence/adapter.log",
            "sha256": "e83167e6008a92ca3728792386b9b0b9cc4d59bb113451fec1812ac89bee7e29"
          },
          "id": "snappy-compression-roundtrip",
          "purposes": [
            "consumer-configure",
            "consumer-build",
            "consumer-run"
          ],
          "result": "PASS"
        }
      ],
      "license_paths": [
        "COPYING"
      ],
      "license_spdx": "BSD-3-Clause",
      "licenses": {
        "COPYING": "55172044f7e241207117448a4d9d6ba1d0925c8ad66b5d4c08c70adfa9cc3de6"
      },
      "name": "snappy",
      "patches": [],
      "prefix_evidence": {
        "path": "Build/dependencies/snappy/evidence/prefix-report.json",
        "sha256": "9e8238691bd7eae6d72aff7a7b4d67b806a0d538207c0449ac98cc491b1f8f92"
      },
      "prefix_manifest_sha256": "95faf774c699259b3c5da8d0d79694ed60a1b70c17a03e5704b8ca5c484cac64",
      "role": "aggregate",
      "source_date_epoch": 1743002362,
      "source_identity": "6af9287fbdb913f0794d0148c6aa43b58e63c8e3",
      "source_kind": "git",
      "source_tag": "1.2.2",
      "source_tree_sha256": "6e3dda3fa8c40bdc79d77fe2f68e4c5d7b703387367bbcda7fe12131849ceb18",
      "source_url": "https://github.com/google/snappy.git",
      "upstream_checks": [
        {
          "compensation": "snappy-compression-roundtrip",
          "description": "Locked upstream GoogleTest suite disabled; installed consumer provides explicit compensation",
          "disabled_option": "-DSNAPPY_BUILD_TESTS=OFF",
          "evidence": {
            "path": "Build/dependencies/snappy/evidence/expanded-options.json",
            "sha256": "bf7285861e404598f573e47f7b55027cddb465430c75445e4dd7fabc0bfe5be4"
          },
          "id": "googletest-omission",
          "purposes": [],
          "reason": "GoogleTest inputs are not pinned in the locked source configuration",
          "result": "OMITTED"
        }
      ],
      "version": "1.2.2"
    },
    {
      "archives": {
        "lib/libleveldb.a": "c23681f17413e777d128abe498a42003bf7ec44cbb7efe153b1be4cb39f75165"
      },
      "installed_checks": [
        {
          "description": "Installed LevelDB target reaches exact accepted Snappy archive; 128-KiB compressed database Put/Get verifies persistent data",
          "evidence": {
            "path": "Build/dependencies/leveldb/evidence/adapter.log",
            "sha256": "cbe29a679d6c77f26869a3608c978dbcf3c6b774161606e99f591ff3f6606cbe"
          },
          "id": "leveldb-snappy-persistent-roundtrip",
          "purposes": [
            "consumer-configure",
            "consumer-build",
            "consumer-run"
          ],
          "result": "PASS"
        }
      ],
      "license_paths": [
        "LICENSE"
      ],
      "license_spdx": "BSD-3-Clause",
      "licenses": {
        "LICENSE": "ccc19f1da0798ed666609b65a5b44dd8b3abe6fc08b9c0592eb76e82e174db19"
      },
      "name": "leveldb",
      "patches": [],
      "prefix_evidence": {
        "path": "Build/dependencies/leveldb/evidence/prefix-report.json",
        "sha256": "f03cc4423905ce7615e62e665ac4d82d16d4fc6788d21fc1426124721eaad0e5"
      },
      "prefix_manifest_sha256": "c8440f26a9d5013a219a5ee1c21752c97f37cf88a9bdbc1b1d25bc60b333627b",
      "role": "aggregate",
      "source_date_epoch": 1614113677,
      "source_identity": "99b3c03b3284f5886f9ef9a4ef703d57373e61be",
      "source_kind": "git",
      "source_tag": "1.23",
      "source_tree_sha256": "b91ddef6557cac0d83ac0938f6ef3f4d70effa9eed32f2691950fd6d103a0c0d",
      "source_url": "https://github.com/google/leveldb.git",
      "upstream_checks": [
        {
          "compensation": "leveldb-snappy-persistent-roundtrip",
          "description": "Locked upstream GoogleTest suite disabled; installed consumer provides explicit compensation",
          "disabled_option": "-DLEVELDB_BUILD_TESTS=OFF",
          "evidence": {
            "path": "Build/dependencies/leveldb/evidence/expanded-options.json",
            "sha256": "78a3c972bc3f0d683e9b2287ff3558cc24770d1e2ec0abe09d6fa638145cdcea"
          },
          "id": "googletest-omission",
          "purposes": [],
          "reason": "GoogleTest inputs are not pinned in the locked source configuration",
          "result": "OMITTED"
        }
      ],
      "version": "1.23"
    },
    {
      "archives": {
        "lib/libboost_atomic.a": "403a44d26ed525bde9dbb2853e01fe2a0835d9d8db498b01c62b9ff3500e7712",
        "lib/libboost_chrono.a": "9c36fa655f30147e79a871cb174b40d7bdadb7e7a43a1febf7ef7163339a7434",
        "lib/libboost_container.a": "5b4f15f7d2d556c152789501b4e29f38dc2accfeff8df8da249ff3465e63a3ff",
        "lib/libboost_date_time.a": "97eb4a6aec1a12b4b0822d2be72ae7d8c86e6532417a5bbac7a9e64e12e54540",
        "lib/libboost_exception.a": "f7ab857516212a1086cc9918498c6a31e98dd894b2f2b504833e5ce9d2195003",
        "lib/libboost_regex.a": "e5bb962ff8ff0a00f9aa84afdf527937ad354e6acd641fcdc3236239709b5e31",
        "lib/libboost_thread.a": "815f8143889462c805091603a45e9545d75570f605dc0a30ce50ed9c97a2d1a4"
      },
      "installed_checks": [
        {
          "description": "Installed regex target matches/rejects values and thread target executes and joins; imported archives remain prefix-bound",
          "evidence": {
            "path": "Build/dependencies/boost/evidence/adapter.log",
            "sha256": "ee16450ac322bfc1e16b438ecfeaaf32bdd057974985a1fe4ec02523873fa608"
          },
          "id": "boost-regex-and-thread",
          "purposes": [
            "consumer-configure",
            "consumer-build",
            "consumer-run"
          ],
          "result": "PASS"
        }
      ],
      "license_paths": [
        "LICENSE_1_0.txt"
      ],
      "license_spdx": "BSL-1.0",
      "licenses": {
        "LICENSE_1_0.txt": "c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566"
      },
      "name": "boost",
      "patches": [
        {
          "path": "config/patches/boost-1.90.0-relocatable-cmake.patch",
          "sha256": "8b499642cfb6feee4bb41ef2b9edd16c9c66250d7e5801bae113c223310f97d9"
        }
      ],
      "prefix_evidence": {
        "path": "Build/dependencies/boost/evidence/prefix-report.json",
        "sha256": "3512fb0cf23aeb451c1f958f76fc0fe645f43d50307b8c68542231342e1c1c58"
      },
      "prefix_manifest_sha256": "21289c5dd03b82e4c9761e9e88ae29f4167b0a221e3dfdb93149ffe06538f8ff",
      "role": "build-only",
      "source_date_epoch": 1764771748,
      "source_identity": "49551aff3b22cbc5c5a9ed3dbc92f0e23ea50a0f7325b0d198b705e8ee3fc305",
      "source_kind": "archive",
      "source_tag": null,
      "source_tree_sha256": "3b5de250b4466b2c655e1b2e00c9d0fa43bd33d4cb219f9bc2bec412d8bc27e2",
      "source_url": "https://archives.boost.io/release/1.90.0/source/boost_1_90_0.tar.bz2",
      "upstream_checks": [
        {
          "description": "Pinned Boost regex/thread bootstrap and static build; this record does not claim an upstream test suite ran",
          "evidence": {
            "path": "Build/dependencies/boost/evidence/adapter.log",
            "sha256": "ee16450ac322bfc1e16b438ecfeaaf32bdd057974985a1fe4ec02523873fa608"
          },
          "id": "locked-regex-thread-build",
          "purposes": [
            "bootstrap",
            "build"
          ],
          "result": "PASS"
        }
      ],
      "version": "1.90.0"
    }
  ],
  "effective_closure": [
    [
      "core",
      "stage/lib/libairdcpp.a"
    ],
    [
      "component:bzip2",
      "lib/libbz2.a"
    ],
    [
      "component:zlib",
      "lib/libz.a"
    ],
    [
      "component:openssl",
      "lib/libssl.a"
    ],
    [
      "component:openssl",
      "lib/libcrypto.a"
    ],
    [
      "component:miniupnpc",
      "lib/libminiupnpc.a"
    ],
    [
      "component:leveldb",
      "lib/libleveldb.a"
    ],
    [
      "component:libmaxminddb",
      "lib/libmaxminddb.a"
    ],
    [
      "component:snappy",
      "lib/libsnappy.a"
    ],
    [
      "apple-sdk",
      "usr/lib/libiconv.2.tbd"
    ]
  ],
  "host": {
    "architecture": "arm64",
    "deployment_target": "14.0",
    "os_version": "26.5.1",
    "sdk_version": "26.5"
  },
  "known_limitations": [
    "No Dist or aggregate archive; collision/coalescing/member mapping and two-clean-build byte reproducibility belong to Phase 7",
    "Native execution on recorded macOS 26.5.1 does not prove actual runtime behavior on macOS 14",
    "Deployment policy is supported by recorded flags and every available member/executable build-version command; unavailable member metadata is not invented",
    "Original failed generated version.inc predecessor bytes are unavailable; retained forensic bytes are not claimed to be its immediate predecessor",
    "Final whole-branch review and final full-gate rerun follow this tracked report checkpoint"
  ],
  "lock_sha256": "d4a4b7a5f7bdc7f6a7e9076db9fa4113a5771c2000c72abf06b70c164230cddd",
  "omissions": [
    "snappy GoogleTest omitted: unpinned test inputs; installed compression round-trip and target-provenance check compensate",
    "leveldb GoogleTest omitted: unpinned test inputs; installed 128-KiB Snappy-compressed database Put/Get and exact link provenance compensate"
  ],
  "openssl_lts_exception": "OpenSSL 3.5.8 uses the reviewed 3.5 LTS line instead of the prior 3.6.4 discovery line; all current evidence was recaptured",
  "openssl_runtime_defaults": {
    "configured": {
      "ENGINESDIR": "/usr/local/lib/engines-3",
      "MODULESDIR": "/usr/local/lib/ossl-modules",
      "OPENSSLDIR": "/usr/local/ssl"
    },
    "lock_fingerprint": "d4a4b7a5f7bdc7f6a7e9076db9fa4113a5771c2000c72abf06b70c164230cddd",
    "observed": [
      "/usr/local/lib/engines-3",
      "/usr/local/lib/ossl-modules",
      "/usr/local/ssl",
      "/usr/local/ssl/cert.pem",
      "/usr/local/ssl/certs",
      "/usr/local/ssl/ct_log_list.cnf",
      "/usr/local/ssl/private"
    ],
    "version": "3.5.8"
  },
  "retry_history": [
    {
      "attempt_count": 4,
      "component": "bzip2",
      "preserved_manifests": [
        {
          "path": "Build/dependencies/bzip2/evidence/attempts/0001/sha256.txt",
          "sha256": "3cca3106048ae32fe09e8761bd2a72f83097bda04a87f296a1b6f2b9baa3eeaa"
        },
        {
          "path": "Build/dependencies/bzip2/evidence/attempts/0002/sha256.txt",
          "sha256": "cf5a1ce040c2242763087b7247332b16c460193ca56bd52c0c3bbbb5675ef8da"
        },
        {
          "path": "Build/dependencies/bzip2/evidence/attempts/0003/sha256.txt",
          "sha256": "47853772f25f2867e168aba7c37ebab9a495a36af8049cde0f02b95d110c80cc"
        },
        {
          "path": "Build/dependencies/bzip2/evidence/attempts/0004/sha256.txt",
          "sha256": "e140fb10d59bf167cd48d3a3ae0ae8eb65fc9ff1cbd95530f1b3f1f2d07868b7"
        }
      ]
    },
    {
      "attempt_count": 4,
      "component": "zlib",
      "preserved_manifests": [
        {
          "path": "Build/dependencies/zlib/evidence/attempts/0001/sha256.txt",
          "sha256": "8433e67aee2eb8cdb81837bc3659e23c0e3131913cbe049ae5d91451fc7074c3"
        },
        {
          "path": "Build/dependencies/zlib/evidence/attempts/0002/sha256.txt",
          "sha256": "12686848e16544b471837ee0e0abb09f1003d2d45f7b3bb95a327027cc6da320"
        },
        {
          "path": "Build/dependencies/zlib/evidence/attempts/0003/sha256.txt",
          "sha256": "1d04f9b78b81f9e9e49fe261dd30fe69f53fb43513a26577f9b9e0d5b20ab70c"
        },
        {
          "path": "Build/dependencies/zlib/evidence/attempts/0004/sha256.txt",
          "sha256": "c0c42484c198b69c8d832a796a48328c8c294577b1f6ac15c7765b6385ca381b"
        }
      ]
    },
    {
      "attempt_count": 4,
      "component": "openssl",
      "preserved_manifests": [
        {
          "path": "Build/dependencies/openssl/evidence/attempts/0001/sha256.txt",
          "sha256": "fd5774a603bce2b46e3a470e787bb18c54f80648d12f2e78a09f24afa592f493"
        },
        {
          "path": "Build/dependencies/openssl/evidence/attempts/0002/sha256.txt",
          "sha256": "a9edd2ff36ed84f975ac5948a620be4b552aca1be30f21a6ae705be4a970641d"
        },
        {
          "path": "Build/dependencies/openssl/evidence/attempts/0003/sha256.txt",
          "sha256": "909b1aaa5b7ce4189c4436eff76f855d3e281f33c5fffc657f52eddfffb94f9e"
        },
        {
          "path": "Build/dependencies/openssl/evidence/attempts/0004/sha256.txt",
          "sha256": "77ba51fcb09b329f03dfc1eb52f0ac06a45f076a2005472e073ba1b0c18affad"
        }
      ]
    },
    {
      "attempt_count": 4,
      "component": "miniupnpc",
      "preserved_manifests": [
        {
          "path": "Build/dependencies/miniupnpc/evidence/attempts/0001/sha256.txt",
          "sha256": "32e56f97a397f70ccd0b55aece65ef789810b5aba938a0502ddee14b22bcc966"
        },
        {
          "path": "Build/dependencies/miniupnpc/evidence/attempts/0002/sha256.txt",
          "sha256": "7968f9fd004134d0fef023792e3f1575f39244dab0feb90a24227185c1041e1d"
        },
        {
          "path": "Build/dependencies/miniupnpc/evidence/attempts/0003/sha256.txt",
          "sha256": "6594c0c2c7e88b9c21180930e31de0e347f5adbe80621b32e62bdb8297069107"
        },
        {
          "path": "Build/dependencies/miniupnpc/evidence/attempts/0004/sha256.txt",
          "sha256": "06d1bc244750dcbf4aa863e7e13428c6f17967ccfbe3566a7108ef559e327d21"
        }
      ]
    },
    {
      "attempt_count": 4,
      "component": "libmaxminddb",
      "preserved_manifests": [
        {
          "path": "Build/dependencies/libmaxminddb/evidence/attempts/0001/sha256.txt",
          "sha256": "45060000246b3446eb9ff5ec00960f3dad88c7604a810d96d2ff3c9671999ba1"
        },
        {
          "path": "Build/dependencies/libmaxminddb/evidence/attempts/0002/sha256.txt",
          "sha256": "4063da2c132b34f033670dc85820ca7d6a18900d1533c4f10867620768d4d4d1"
        },
        {
          "path": "Build/dependencies/libmaxminddb/evidence/attempts/0003/sha256.txt",
          "sha256": "f1a0a5847779f6a8a797337ec53dc41ae203db95f73f69f331cb2caaa20bad8a"
        },
        {
          "path": "Build/dependencies/libmaxminddb/evidence/attempts/0004/sha256.txt",
          "sha256": "4001cd942b922c94631419e2a8d451901de211059a493b6ac484347381ac19c9"
        }
      ]
    },
    {
      "attempt_count": 4,
      "component": "snappy",
      "preserved_manifests": [
        {
          "path": "Build/dependencies/snappy/evidence/attempts/0001/sha256.txt",
          "sha256": "68c707d7992469dd25fe13f63cb72e21ffeca6f44747d8cb3de2e00441a9a55c"
        },
        {
          "path": "Build/dependencies/snappy/evidence/attempts/0002/sha256.txt",
          "sha256": "e382965b6b6a2cfc4f9d3fcf87e467ba7b33f40afd6f8f3c9cda35baf02edaa1"
        },
        {
          "path": "Build/dependencies/snappy/evidence/attempts/0003/sha256.txt",
          "sha256": "b905662339201c63afff90606980aabb5dd7b14f56df9635805878827d337551"
        },
        {
          "path": "Build/dependencies/snappy/evidence/attempts/0004/sha256.txt",
          "sha256": "9530b4471deb2d658e60603dace8492d44f9c96e7a254e7708d20bbcc67c9404"
        }
      ]
    },
    {
      "attempt_count": 3,
      "component": "leveldb",
      "preserved_manifests": [
        {
          "path": "Build/dependencies/leveldb/evidence/attempts/0001/sha256.txt",
          "sha256": "67e18265573ecd9297332c49311b594574bc9e960540a29413cd83e952a5c997"
        },
        {
          "path": "Build/dependencies/leveldb/evidence/attempts/0002/sha256.txt",
          "sha256": "d0eb7a8a7604b7efa4625659674ce2c7220f1abfb92793fa3572c1a9e7718761"
        },
        {
          "path": "Build/dependencies/leveldb/evidence/attempts/0003/sha256.txt",
          "sha256": "a696560140d18df653cd4fb8ed634f9176f95dd5a245c1bce479a10356fd43da"
        }
      ]
    },
    {
      "attempt_count": 3,
      "component": "boost",
      "preserved_manifests": [
        {
          "path": "Build/dependencies/boost/evidence/attempts/0001/sha256.txt",
          "sha256": "5835ff4b681c0b92cd9c00b043d7729edeeac4ff4c57cef76f6c903ef6baac13"
        },
        {
          "path": "Build/dependencies/boost/evidence/attempts/0002/sha256.txt",
          "sha256": "f2175dce4729ffe706004eaec41d84e4ffe18733f08d1868e563942755573b7d"
        },
        {
          "path": "Build/dependencies/boost/evidence/attempts/0003/sha256.txt",
          "sha256": "af5ba4e8a51d4409cd9cac382fb2210b99745d3fc77850bcdb591a12dbd893e7"
        }
      ]
    },
    {
      "attempt": "0001",
      "build_exit": "1",
      "component": "Core",
      "evidence": {
        "path": "Build/airdcpp-core/reproducible-release/attempts/0001/prior-output-manifest.json",
        "sha256": "789f1502f199afac64451dfa2ead302a5647fe6dbdf208655f9cf77b8a24689f"
      }
    },
    {
      "attempt": "0002",
      "build_exit": "1",
      "component": "Core",
      "evidence": {
        "path": "Build/airdcpp-core/reproducible-release/attempts/0002/prior-output-manifest.json",
        "sha256": "cc6ab19fb011da2aa37b98be7628ff571126b6c65d40b5129fef96d2f8e172f6"
      }
    },
    {
      "attempt": "0003",
      "build_exit": "0",
      "component": "Core",
      "evidence": {
        "path": "Build/airdcpp-core/reproducible-release/attempts/0003/prior-output-manifest.json",
        "sha256": "402ae64152764fd44941d5a936ba5ec2233000ccc01e905ee9fa7984dd9399ff"
      }
    }
  ],
  "schema_version": 1,
  "status": "pending",
  "system_inputs": [
    "explicit SDK Iconv",
    "implicit libc++",
    "implicit libSystem",
    "Apple frameworks: none"
  ],
  "tools": {
    "ar": {
      "sha256": "e49ffad64ad1cee722540fc5ecb00a230fd8071680682c60d9c851029d20e814",
      "version": "Apple toolchain clang --version:\nApple clang version 21.0.0 (clang-2100.1.1.101)\nTarget: arm64-apple-darwin25.5.0\nThread model: posix"
    },
    "clang": {
      "sha256": "7def90dd8829726686213a747fc5bff1583df933dae5edc55d755479e0bfe00a",
      "version": "Apple clang version 21.0.0 (clang-2100.1.1.101)\nTarget: arm64-apple-darwin25.5.0\nThread model: posix"
    },
    "clang++": {
      "sha256": "7def90dd8829726686213a747fc5bff1583df933dae5edc55d755479e0bfe00a",
      "version": "Apple clang version 21.0.0 (clang-2100.1.1.101)\nTarget: arm64-apple-darwin25.5.0\nThread model: posix"
    },
    "cmake": {
      "sha256": "01bb5214684f5390e96e0d6aef7aafd7415b77ecbcfd59f6b55b018d8de0d9a2",
      "version": "cmake version 4.4.3\nCMake suite maintained and supported by Kitware (kitware.com/cmake)."
    },
    "lipo": {
      "sha256": "661f3514be6992bb66346e3e48d974fc0ce5b9be5eab55321eabf4818fb3bf28",
      "version": "Apple toolchain clang --version:\nApple clang version 21.0.0 (clang-2100.1.1.101)\nTarget: arm64-apple-darwin25.5.0\nThread model: posix"
    },
    "make": {
      "sha256": "179301dcb41ea78accc3fa0048a7e6f6710d891945a751a34addd622020c1818",
      "version": "GNU Make 3.81\nCopyright (C) 2006  Free Software Foundation, Inc.\nThis is free software; see the source for copying conditions.\nThere is NO warranty; not even for MERCHANTABILITY or FITNESS FOR A\nPARTICULAR PURPOSE.\nThis program built for i386-apple-darwin11.3.0"
    },
    "ninja": {
      "sha256": "48761628046784f59bd789f5a72b88da99205c5849e5d19ae4d317854ae09e83",
      "version": "1.13.2"
    },
    "nm": {
      "sha256": "d910f3acb104791e5475254000ede2aa129aa1a42eafcc7f5bdb27afffc642dc",
      "version": "llvm-nm, compatible with GNU nm\nApple LLVM version 21.0.0\n  Optimized build."
    },
    "otool": {
      "sha256": "be184bb7054565eae25193e45e4235ea2d372c1eb6288ce900b2fad6d9dcc3f3",
      "version": "llvm-otool(1): Apple Inc. version cctools-1040\notool(1): Apple Inc. version cctools-1040\ndisassembler: LLVM version 21.0.0"
    },
    "patch": {
      "sha256": "256e7e3fb214fda4971309e27e685623be5238f1975364d887d277eb42e52404",
      "version": "patch 2.0-12u11-Apple"
    },
    "perl": {
      "sha256": "abda2bfd23a6c9a8e57adf2291f0aea4abd8faf440558ee49fe4ced55e8d9ad0",
      "version": "This is perl 5, version 34, subversion 1 (v5.34.1) built for darwin-thread-multi-2level\n(with 2 registered patches, see perl -V for more detail)\nCopyright 1987-2022, Larry Wall\nPerl may be copied only under the terms of either the Artistic License or the\nGNU General Public License, which may be found in the Perl 5 source kit.\nComplete documentation for Perl, including FAQ lists, should be found on\nthis system using \"man perl\" or \"perldoc perl\".  If you have access to the\nInternet, point your browser at http://www.perl.org/, the Perl Home Page."
    },
    "pkg-config": {
      "role": "host inventory observation; not a Phase 6 consumer library input",
      "version": "pkgconf 2.5.1"
    },
    "python3": {
      "sha256": "87d4df53fd91304be5bac391fb204643c36b7df2023c04a0953bcbc7d4fdf634",
      "version": "Python 3.14.7"
    },
    "ranlib": {
      "sha256": "229eb9d8027953d2aee0590f983eed587d52bdd1ebc21114a62ce693f77b03f1",
      "version": "Apple Inc. version cctools_ld-1267"
    },
    "strings": {
      "sha256": "52ddfe491e72485fa7425f7e0f7447d99764cb584b1aec72633b18e70d8714e9",
      "version": "Apple toolchain clang --version:\nApple clang version 21.0.0 (clang-2100.1.1.101)\nTarget: arm64-apple-darwin25.5.0\nThread model: posix"
    },
    "xcrun": {
      "sha256": "a439970aea2b4e435eac6518ff62c97fd1c57d8c731974027ad211b515c7a7b8",
      "version": "xcrun version 72."
    }
  }
}
```
