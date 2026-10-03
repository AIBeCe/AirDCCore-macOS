import subprocess
import tempfile
import unittest
import importlib.util
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
NORMALIZER = ROOT / "scripts/lib/normalize_link_evidence.py"
SPEC = importlib.util.spec_from_file_location('link_evidence', NORMALIZER)
EVIDENCE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EVIDENCE)


class LinkEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="airdc-link-evidence-")
        self.work = Path(self.temporary.name)
        self.project = self.work / "Project Root"
        self.project.mkdir()
        self.command = self.work / "link-command.txt"
        self.omissions = self.work / "omissions.tsv"
        self.output = self.work / "link-interface.tsv"
        self.omissions.write_text(
            "pass\tordinal\tlogical\tclassification\tbuild_exit\n"
            "1\t1\tBZip2\trequired\t1\n",
            encoding="utf-8",
        )

    def tearDown(self):
        self.temporary.cleanup()

    def run_normalizer(self, *extra):
        return subprocess.run(
            [
                "python3",
                str(NORMALIZER),
                "--project-root",
                str(self.project),
                "--command",
                str(self.command),
                "--omissions",
                str(self.omissions),
                "--output",
                str(self.output),
                *extra,
            ],
            text=True,
            capture_output=True,
        )

    def test_order_deduplication_and_framework_pairing(self):
        core = self.project / "Build/airdcpp-core/link-interface/stage/lib/libairdcpp.a"
        self.command.write_text(
            f'/usr/bin/clang++ main.o "-Wl,-force_load,{core}" '
            '"/opt/homebrew/opt/bzip2/lib/libbz2.a" '
            '"/opt/homebrew/opt/bzip2/lib/libbz2.a" '
            '-framework CoreFoundation -lSystem -o airdcpp-smoke\n',
            encoding="utf-8",
        )

        result = self.run_normalizer()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.output.read_text(encoding="utf-8"),
            "1\tcore\tstage/lib/libairdcpp.a\n"
            "2\tlibrary\t/opt/homebrew/opt/bzip2/lib/libbz2.a\n"
            "3\tframework\tCoreFoundation\n"
            "4\tsystem\t-lSystem\n",
        )

    def test_exact_project_root_is_normalized_without_prefix_collision(self):
        inside = self.project / "vendor/libinside.a"
        outside = Path(f"{self.project}-other/vendor/liboutside.a")
        self.command.write_text(
            f'/usr/bin/clang++ main.o "{inside}" "{outside}" -o app\n', encoding="utf-8"
        )

        result = self.run_normalizer()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.output.read_text(encoding="utf-8"),
            f"1\tlibrary\t$PROJECT_ROOT/vendor/libinside.a\n"
            f"2\tlibrary\t{outside}\n",
        )

    def test_sdk_stub_is_retained_as_a_system_item(self):
        stub = "/Applications/Xcode.app/SDK/usr/lib/libiconv.tbd"
        self.command.write_text(f'/usr/bin/clang++ main.o "{stub}" -o app\n', encoding="utf-8")

        result = self.run_normalizer()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.output.read_text(encoding="utf-8"), f"1\tsystem\t{stub}\n")

    def test_malformed_framework_does_not_publish_output(self):
        self.output.write_text("preserve me\n", encoding="utf-8")
        self.command.write_text("/usr/bin/clang++ main.o -framework\n", encoding="utf-8")

        result = self.run_normalizer()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("link-evidence: error:", result.stderr)
        self.assertIn("framework", result.stderr)
        self.assertEqual(self.output.read_text(encoding="utf-8"), "preserve me\n")

    def test_allowed_prefixes_emit_identity_and_relative_paths(self):
        prefix = self.project / 'Build/prefix/openssl'
        sdk = self.work / 'SDK with spaces'
        for path in (prefix/'lib/libssl.a', prefix/'lib/libcrypto.a', sdk/'usr/lib/libiconv.tbd'):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.touch()
        self.command.write_text(f'clang++ main.o "{prefix}/lib/libssl.a" "{prefix}/lib/libcrypto.a" "{sdk}/usr/lib/libiconv.tbd" -o app\n')
        result = self.run_normalizer('--allowed-prefix', f'openssl={prefix}',
                                     '--allowed-prefix', f'apple-sdk={sdk}')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.output.read_text(),
                         '1\tcomponent:openssl\tlib/libssl.a\n'
                         '2\tcomponent:openssl\tlib/libcrypto.a\n'
                         '3\tapple-sdk\tusr/lib/libiconv.tbd\n')

    def test_unclassified_link_input_does_not_replace_evidence(self):
        prefix = self.project/'allowed'
        prefix.mkdir()
        self.output.write_text('preserve me\n')
        for path in (str(prefix)+'-other/libevil.a', '/opt/homebrew/lib/libevil.dylib', 'librelative.a'):
            with self.subTest(path=path):
                self.command.write_text(f'clang++ main.o "{path}" -o app\n')
                result = self.run_normalizer('--allowed-prefix', f'bzip2={prefix}')
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('unclassified link input', result.stderr)
                self.assertEqual(self.output.read_text(), 'preserve me\n')

    def test_symlink_escape_and_overlapping_prefixes_are_rejected(self):
        prefix = self.project/'allowed'
        prefix.mkdir()
        outside = self.work/'liboutside.a'
        outside.touch()
        (prefix/'libescape.a').symlink_to(outside)
        self.command.write_text(f'clang++ main.o "{prefix}/libescape.a" -o app\n')
        result = self.run_normalizer('--allowed-prefix', f'bzip2={prefix}')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('unclassified link input', result.stderr)
        result = self.run_normalizer('--allowed-prefix', f'bzip2={prefix}',
                                     '--allowed-prefix', f'zlib={prefix}')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('overlapping', result.stderr)

    def test_adr_rejects_changed_physical_closure_and_system_inventory(self):
        adr = (ROOT/'docs/decisions/0001-aggregate-static-distribution.md').read_text()
        expected = [('core', 'stage/lib/libairdcpp.a'), ('component:bzip2', 'lib/libbz2.a'),
                    ('component:zlib', 'lib/libz.a'), ('component:openssl', 'lib/libssl.a'),
                    ('component:openssl', 'lib/libcrypto.a'), ('component:miniupnpc', 'lib/libminiupnpc.a'),
                    ('component:leveldb', 'lib/libleveldb.a'), ('component:libmaxminddb', 'lib/libmaxminddb.a'),
                    ('component:snappy', 'lib/libsnappy.a'), ('apple-sdk', 'usr/lib/libiconv.2.tbd')]
        EVIDENCE.assert_adr_closure(expected, adr, 'usr/lib/libiconv.2.tbd')
        swapped = expected.copy()
        swapped[3], swapped[4] = swapped[4], swapped[3]
        for rows in (swapped, expected+[('component:boost','lib/libboost_thread.a')],
                     expected+[('framework','CoreFoundation')], expected+[('system','-lresolv')],
                     expected+[('library','/opt/homebrew/lib/libforeign.dylib')]):
            with self.subTest(rows=rows):
                with self.assertRaisesRegex(ValueError, 'link contract differs from ADR 0001'):
                    EVIDENCE.assert_adr_closure(rows, adr, 'usr/lib/libiconv.2.tbd')
        with self.assertRaisesRegex(ValueError, 'link contract differs from ADR 0001'):
            EVIDENCE.assert_adr_closure(expected, adr.replace('measured Apple framework requirement: none',
                                                          'measured Apple framework requirement: CoreFoundation'),
                                        'usr/lib/libiconv.2.tbd')

    def test_openssl_defaults_are_bounded_runtime_paths_not_general_usr_local(self):
        defaults = {'OPENSSLDIR':'/usr/local/ssl', 'ENGINESDIR':'/usr/local/lib/engines-3',
                    'MODULESDIR':'/usr/local/lib/ossl-modules'}
        strings = ('/usr/local/ssl\n/usr/local/ssl/cert.pem\n/usr/local/ssl/certs\n'
                   '/usr/local/lib/engines-3\n/usr/local/lib/ossl-modules\n'
                   '/usr/local/ssl-evil\n/usr/local/ssl/../opt/evil.a\n'
                   '/usr/local/lib/libforeign.a\n')
        observed, rejected = EVIDENCE.classify_runtime_defaults(strings, defaults)
        self.assertEqual(rejected, ['/usr/local/lib/libforeign.a','/usr/local/ssl-evil',
                                    '/usr/local/ssl/../opt/evil.a'])
        self.assertIn('/usr/local/ssl/cert.pem',observed)

    def test_malformed_omission_row_does_not_publish_output(self):
        self.output.write_text("preserve me\n", encoding="utf-8")
        self.command.write_text("/usr/bin/clang++ main.o -lSystem -o app\n", encoding="utf-8")
        self.omissions.write_text("pass\tordinal\tlogical\tclassification\tbuild_exit\n1\t1\tBZip2\n", encoding="utf-8")

        result = self.run_normalizer()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("omission", result.stderr)
        self.assertEqual(self.output.read_text(encoding="utf-8"), "preserve me\n")


if __name__ == "__main__":
    unittest.main()
