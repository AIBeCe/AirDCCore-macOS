#!/bin/sh
set -eu

# Read-only acceptance of the already-linked external ARM64 consumer.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
. "$ROOT/tests/test_helper.sh"

[ "${AIRDCCORE_RUN_LINK_TESTS:-0}" = 1 ] ||
  fail 'set AIRDCCORE_RUN_LINK_TESTS=1 for live Gate 4'

. "$ROOT/scripts/lib/upstream.sh"
. "$ROOT/scripts/lib/configure.sh"
load_upstream_config "$ROOT/config/upstream.env" || fail 'invalid upstream pin'

REPORT=$ROOT/docs/reports/2026-09-21-gate-4-consumer-link.md
CHECKOUT=$ROOT/Source/airdcpp-core
BUILD_ROOT=$ROOT/Build/airdcpp-core
CORE=$BUILD_ROOT/core-release
ARCHIVE=$CORE/upstream/libairdcpp.a
LINK=$BUILD_ROOT/link-interface
STAGE=$LINK/stage
EXECUTABLE=$LINK/full/airdcpp-smoke

assert_file_present "$REPORT"

gate_preserved_snapshot() (
  cd "$BUILD_ROOT" || exit 1
  paths=$(find . -path ./link-interface -prune -o -print | LC_ALL=C sort) || exit 1
  while IFS= read -r path; do
    [ "$path" != . ] || continue
    if [ -L "$path" ]; then
      target=$(readlink "$path") || exit 1
      printf 'link %s %s\n' "$path" "$target"
    elif [ -f "$path" ]; then
      digest=$(shasum -a 256 "$path") || exit 1
      printf 'file %s %s\n' "$path" "${digest%% *}"
    elif [ -d "$path" ]; then
      printf 'dir %s\n' "$path"
    else
      exit 1
    fi
  done <<EOF
$paths
EOF
)

[ -d "$CHECKOUT" ] && [ ! -L "$CHECKOUT" ] || fail 'pinned source checkout missing or symlinked'
assert_eq "$(git -C "$CHECKOUT" rev-parse HEAD)" "$AIRDCPP_CORE_COMMIT" 'pinned upstream commit'
assert_eq "$(git -C "$CHECKOUT" remote get-url --all origin)" "$AIRDCPP_CORE_URL" 'pinned upstream origin'
if git -C "$CHECKOUT" symbolic-ref -q HEAD >/dev/null 2>&1; then fail 'upstream HEAD must be detached'; fi
git -C "$CHECKOUT" diff --quiet HEAD -- || fail 'upstream tracked files changed'
git -C "$CHECKOUT" diff --cached --quiet -- || fail 'upstream staged files changed'
assert_eq "$(git -C "$CHECKOUT" ls-files --others --exclude-standard)" '' 'upstream untracked source'
ignored=$(git -C "$CHECKOUT" ls-files --others --ignored --exclude-standard)
while IFS= read -r path; do
  [ -n "$path" ] || continue
  case "$path" in
    airdcpp/core/version.inc|airdcpp/core/localization/StringDefs.cpp)
      [ -f "$CHECKOUT/$path" ] && [ ! -L "$CHECKOUT/$path" ] || fail "unsafe generated source: $path" ;;
    *) fail "unexpected ignored upstream path: $path" ;;
  esac
done <<EOF
$ignored
EOF

[ -d "$LINK" ] && [ ! -L "$LINK" ] || fail 'link-interface evidence missing or symlinked'
links=$(find "$LINK" -type l -print) || fail 'failed to inspect link-interface symlinks'
[ -z "$links" ] || fail "symlinked link-interface evidence: $links"
before_parent=$(configure_tree_snapshot "$ROOT") || fail 'failed to snapshot parent'
before_source=$(configure_upstream_snapshot "$CHECKOUT") || fail 'failed to snapshot source'
before_preserved=$(gate_preserved_snapshot) || fail 'failed to snapshot Gate 2/Core evidence'

for evidence in build-inputs.txt build-exit-code.txt archive-members.tsv \
    archive-symbols.txt archive-strings.txt archive-ar-table.txt archive-sha256.txt; do
  assert_file_present "$CORE/$evidence"
done
assert_line "$CORE/build-exit-code.txt" 0 'Gate 3 build status'
assert_line "$CORE/build-inputs.txt" "upstream.commit=$AIRDCPP_CORE_COMMIT" 'Gate 3 source pin'
assert_line "$CORE/build-inputs.txt" 'source.file_prefix_map=airdcpp-core' 'Gate 3 source prefix-map'
assert_file_present "$ARCHIVE"

TEMP=$(mktemp -d /private/tmp/airdc-gate4.XXXXXX) || fail 'failed to create verification scratch'
trap 'rm -rf -- "$TEMP"' 0 1 2 15
python3 "$ROOT/scripts/lib/inspect_core_archive.py" "$ARCHIVE" \
  "$TEMP/archive-members.tsv" "$TEMP/archive-symbols.txt" || fail 'independent Core archive inspection failed'
/usr/bin/strings "$ARCHIVE" > "$TEMP/archive-strings.txt" || fail 'independent Core string inspection failed'
/usr/bin/ar -t "$ARCHIVE" > "$TEMP/archive-ar-table.txt" || fail 'independent Core table inspection failed'
(cd "$CORE" && shasum -a 256 upstream/libairdcpp.a) > "$TEMP/archive-sha256.txt" || fail 'independent Core hash failed'
for evidence in archive-members.tsv archive-symbols.txt archive-strings.txt \
    archive-ar-table.txt archive-sha256.txt; do
  cmp -s "$CORE/$evidence" "$TEMP/$evidence" || fail "Gate 3 $evidence differs from actual archive"
done
archive_hash=$(shasum -a 256 "$ARCHIVE"); archive_hash=${archive_hash%% *}
members_hash=$(shasum -a 256 "$CORE/archive-members.tsv"); members_hash=${members_hash%% *}

[ -d "$STAGE/include" ] && [ ! -L "$STAGE/include" ] || fail 'staged include tree missing or symlinked'
assert_file_present "$STAGE/lib/libairdcpp.a"
cmp -s "$ARCHIVE" "$STAGE/lib/libairdcpp.a" || fail 'staged Core archive differs from Gate 3 candidate'
stage_links=$(find "$STAGE" -type l -print) || fail 'failed to inspect staged inputs'
[ -z "$stage_links" ] || fail "symlinked staged input: $stage_links"
(cd "$STAGE/include" && find . -type f -print | LC_ALL=C sort | while IFS= read -r path; do shasum -a 256 "$path"; done) \
  > "$TEMP/header-manifest.sha256" || fail 'failed to regenerate staged header manifest'
cmp -s "$LINK/header-manifest.sha256" "$TEMP/header-manifest.sha256" || fail 'staged header manifest differs'
(cd "$CHECKOUT" && find ./airdcpp -path ./airdcpp/modules -prune -o \
  -type f \( -name '*.h' -o -name '*.inc' \) -print | LC_ALL=C sort | \
  while IFS= read -r path; do shasum -a 256 "$path"; done) \
  > "$TEMP/source-header-manifest.sha256" || fail 'failed to regenerate pinned-source header manifest'
cmp -s "$LINK/header-manifest.sha256" "$TEMP/source-header-manifest.sha256" ||
  fail 'staged headers differ from pinned checkout'
header_count=$(wc -l < "$TEMP/header-manifest.sha256" | tr -d ' ')
[ "$header_count" -gt 0 ] || fail 'staged header manifest is empty'
headers_hash=$(shasum -a 256 "$LINK/header-manifest.sha256"); headers_hash=${headers_hash%% *}
cat > "$TEMP/input-manifest.txt" <<EOF
upstream.commit=$AIRDCPP_CORE_COMMIT
core.archive.sha256=$archive_hash
core.members.sha256=$members_hash
headers.manifest.sha256=$headers_hash
architecture=arm64
deployment_target=14.0
build_type=Release
cxx_standard=20
enable_natpmp=OFF
enable_tbb=OFF
EOF
cmp -s "$LINK/input-manifest.txt" "$TEMP/input-manifest.txt" || fail 'consumer input manifest differs'

for evidence in configure-command.txt configure.log configure-exit-code.txt \
    build-command.txt build.log build-exit-code.txt; do
  assert_file_present "$LINK/core-only/$evidence"
done
assert_line "$LINK/core-only/configure-exit-code.txt" 0 'Core-only configure status'
core_only_status=$(cat "$LINK/core-only/build-exit-code.txt")
[ "$core_only_status" -ne 0 ] 2>/dev/null || fail 'Core-only force-load unexpectedly linked'
assert_contains "$(cat "$LINK/core-only/build.log")" 'Undefined symbols' 'Core-only unresolved-symbol evidence'
assert_contains "$(cat "$LINK/core-only/configure-command.txt")" 'AIRDCCORE_TEST_LINK_ITEMS=none' 'Core-only dependency isolation'

for evidence in configure-command.txt configure.log configure-exit-code.txt \
    build-command.txt build.log build-exit-code.txt; do
  assert_file_present "$LINK/full/$evidence"
done
assert_file_present "$LINK/link-command.raw.txt"
assert_line "$LINK/full/configure-exit-code.txt" 0 'full configure status'
assert_line "$LINK/full/build-exit-code.txt" 0 'full link status'
assert_contains "$(cat "$LINK/full/configure-command.txt")" \
  'AIRDCCORE_TEST_LINK_ITEMS=BZip2,ZLIB,OpenSSLSSL,miniupnpc,leveldb,maxminddb,Iconv' \
  'fixed-point full-link inputs'
assert_contains "$(cat "$LINK/full/configure-command.txt")" \
  "AIRDCCORE_LIBRARY=$STAGE/lib/libairdcpp.a" 'staged full-link archive'
recorded_link=$(sed -nE '/(^|[[:space:]])([^[:space:]]*\/)?(clang\+\+|c\+\+)([[:space:]]|$).*airdcpp-smoke/p' \
  "$LINK/full/build.log" | tail -n 1) || fail 'failed to extract recorded full link command'
[ -n "$recorded_link" ] || fail 'full build log has no recorded Apple Clang link command'
assert_line "$LINK/link-command.raw.txt" "$recorded_link" 'recorded full link command'
force_load_fragment="-Xlinker -force_load -Xlinker $STAGE/lib/libairdcpp.a"
force_load_count=$(grep -Fo -- "$force_load_fragment" "$LINK/link-command.raw.txt" | wc -l | tr -d ' ')
assert_eq "$force_load_count" 1 'exact staged archive force-load'
python3 "$ROOT/scripts/lib/normalize_link_evidence.py" \
  --project-root "$ROOT" --command "$LINK/link-command.raw.txt" \
  --omissions "$LINK/omission-results.tsv" --output "$TEMP/link-interface-regenerated.tsv" ||
  fail 'failed to regenerate normalized link interface'

cat > "$TEMP/omission-results.tsv" <<'EOF'
pass	ordinal	logical	classification	build_exit
1	1	BZip2	required	1
1	2	ZLIB	required	1
1	3	OpenSSLSSL	required	1
1	4	OpenSSLCrypto	transitive	0
1	5	miniupnpc	required	1
1	6	leveldb	required	1
1	7	maxminddb	required	1
1	8	BoostThread	transitive	0
1	9	BoostRegex	transitive	0
1	10	Snappy	transitive	0
1	11	Threads	transitive	0
1	12	Iconv	required	1
2	1	BZip2	required	1
2	2	ZLIB	required	1
2	3	OpenSSLSSL	required	1
2	4	miniupnpc	required	1
2	5	leveldb	required	1
2	6	maxminddb	required	1
2	7	Iconv	required	1
EOF
cmp -s "$LINK/omission-results.tsv" "$TEMP/omission-results.tsv" || fail 'fixed-point omission matrix differs'

cat > "$TEMP/link-interface.tsv" <<'EOF'
1	core	stage/lib/libairdcpp.a
2	library	/opt/homebrew/opt/bzip2/lib/libbz2.a
3	library	/opt/homebrew/opt/zlib/lib/libz.dylib
4	library	/opt/homebrew/opt/openssl@3/lib/libssl.dylib
5	library	/opt/homebrew/opt/miniupnpc/lib/libminiupnpc.dylib
6	library	/opt/homebrew/opt/leveldb/lib/libleveldb.1.23.0.dylib
7	library	/opt/homebrew/opt/libmaxminddb/lib/libmaxminddb.dylib
8	library	/opt/homebrew/opt/openssl@3/lib/libcrypto.dylib
9	library	/opt/homebrew/opt/snappy/lib/libsnappy.1.2.2.dylib
10	system	/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/lib/libiconv.2.tbd
EOF
cmp -s "$LINK/link-interface.tsv" "$TEMP/link-interface.tsv" || fail 'normalized ordered link interface differs'
cmp -s "$LINK/link-interface.tsv" "$TEMP/link-interface-regenerated.tsv" ||
  fail 'normalized link interface differs from recorded full link command'

assert_file_present "$EXECUTABLE"
assert_file_present "$LINK/full/build/airdcpp-smoke"
cmp -s "$EXECUTABLE" "$LINK/full/build/airdcpp-smoke" ||
  fail 'published consumer differs from recorded full-link output'
/usr/bin/file -b "$EXECUTABLE" > "$TEMP/binary-file.txt" || fail 'consumer file inspection failed'
/usr/bin/lipo -archs "$EXECUTABLE" > "$TEMP/binary-arch.txt" || fail 'consumer architecture inspection failed'
/usr/bin/otool -L "$EXECUTABLE" > "$TEMP/otool-load-commands.txt" || fail 'consumer load-command inspection failed'
cmp -s "$LINK/binary-file.txt" "$TEMP/binary-file.txt" || fail 'consumer file evidence differs'
cmp -s "$LINK/binary-arch.txt" "$TEMP/binary-arch.txt" || fail 'consumer architecture evidence differs'
cmp -s "$LINK/otool-load-commands.txt" "$TEMP/otool-load-commands.txt" || fail 'consumer load-command evidence differs'
assert_line "$TEMP/binary-arch.txt" arm64 'consumer architecture'
/usr/bin/strings "$EXECUTABLE" > "$TEMP/binary-strings.txt" || fail 'consumer string inspection failed'
sed '1d' "$TEMP/otool-load-commands.txt" > "$TEMP/load-command-body.txt"
for evidence in "$TEMP/binary-strings.txt" "$TEMP/load-command-body.txt" \
    "$LINK/link-interface.tsv"; do
  if grep -F "$ROOT" "$evidence" >/dev/null 2>&1 ||
      { [ -n "${HOME:-}" ] && grep -F "$HOME/" "$evidence" >/dev/null 2>&1; } ||
      grep -Eq '/(Source|Build)/' "$evidence"; then
    fail 'consumer artifact or normalized evidence leaks an absolute home, Source, or Build path'
  fi
done
executable_hash=$(shasum -a 256 "$EXECUTABLE"); executable_hash=${executable_hash%% *}
assert_eq "$executable_hash" '4106951b59ab7da5155e153eb34233234b519a8877efef2a00908fc06735cafe' \
  'consumer executable SHA-256 differs'
assert_contains "$(cat "$REPORT")" "$executable_hash" 'reported consumer executable hash'
xcrun nm "$EXECUTABLE" | c++filt > "$TEMP/binary-symbols.txt" || fail 'consumer symbol inspection failed'
assert_contains "$(cat "$TEMP/binary-symbols.txt")" 'dcpp::getVersionTag()' 'real Core version symbol'
assert_contains "$(cat "$TEMP/binary-symbols.txt")" 'dcpp::getGitCommit()' 'real Core commit symbol'

assert_line "$LINK/run/exit-code.txt" 0 'stored consumer runtime status'
[ ! -s "$LINK/run/stderr.txt" ] || fail 'stored consumer stderr is not empty'
assert_line "$LINK/run/stdout.txt" "AirDC++ Core $AIRDCPP_CORE_COMMIT" 'stored consumer identity'
runtime_status=0
"$EXECUTABLE" > "$TEMP/stdout.txt" 2> "$TEMP/stderr.txt" || runtime_status=$?
assert_eq "$runtime_status" 0 'independent consumer runtime status'
cmp -s "$LINK/run/stdout.txt" "$TEMP/stdout.txt" || fail 'independent consumer stdout differs'
cmp -s "$LINK/run/stderr.txt" "$TEMP/stderr.txt" || fail 'independent consumer stderr differs'

assert_eq "$(git -C "$ROOT" ls-files Source Dependencies Build Dist)" '' 'no generated paths tracked'
[ ! -e "$ROOT/Dependencies" ] && [ ! -L "$ROOT/Dependencies" ] || fail 'Dependencies unexpectedly exists'
[ ! -e "$ROOT/Dist" ] && [ ! -L "$ROOT/Dist" ] || fail 'Dist unexpectedly exists'
assert_eq "$(configure_tree_snapshot "$ROOT")" "$before_parent" 'parent scope after Gate 4'
assert_eq "$(configure_upstream_snapshot "$CHECKOUT")" "$before_source" 'upstream scope after Gate 4'
assert_eq "$(gate_preserved_snapshot)" "$before_preserved" 'Gate 2/Core evidence after Gate 4'

printf 'PASS: Gate 4 verified external ARM64 consumer with %s staged headers and 7 required link items\n' "$header_count"
