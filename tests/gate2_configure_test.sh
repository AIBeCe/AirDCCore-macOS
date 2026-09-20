#!/bin/sh
set -eu

# Catches configure policy/discovery drift, overwritten first-attempt evidence,
# source mutations, and accidental AirDC++ Core compilation or output publication.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
. "$ROOT/tests/test_helper.sh"
. "$ROOT/scripts/lib/upstream.sh"

[ "${AIRDCCORE_RUN_CONFIGURE_TESTS:-0}" = 1 ] ||
  fail "set AIRDCCORE_RUN_CONFIGURE_TESTS=1 to run the real Gate 2 configure test"

# This reviewed evidence contract catches missing/incomplete reports, leaked
# host paths, optional-policy drift, and claims beyond configure-only evidence.
REPORT=$ROOT/docs/reports/2026-09-05-gate-2-native-configure.md
assert_file_present "$REPORT"
while IFS= read -r heading; do
  assert_line "$REPORT" "$heading" "Gate 2 report heading"
done <<'EOF'
## Scope and result
## Source identity and cleanliness
## Host and tool inventory
## Homebrew formula inventory
## Unmodified upstream configure
## Wrapper-only configure
## Adaptations and evidence
## Final deterministic configure
## Deployment target decision
## Optional NAT-PMP and TBB behavior
## Package resolution
## Warnings and failures
## Rerun and scope verification
## Gate 2 review decision
EOF
assert_contains "$(cat "$REPORT")" "Dist is absent" "report publication absence"
assert_contains "$(cat "$REPORT")" "libairdcpp.a is absent" "report Core archive absence"
validate_report_claims() {
awk '
  /^## / { section = $0 }
  {
    lower = tolower($0)
    if (index($0, "/Users/")) bad = "user-home path"
    if ($0 ~ /ENABLE_(NATPMP|TBB)=ON/ &&
        section != "## Unmodified upstream configure" &&
        section != "## Optional NAT-PMP and TBB behavior") bad = "optional ON outside discovery/probe sections"
    # Remove only directly negated predicates/subjects, never an entire line.
    # "No errors" cannot hide a later affirmative claim; nor can a negative
    # compile claim hide an affirmative archive/publication claim (or vice versa).
    claims = lower
    gsub(/(^|[^a-z])(not|never|without|no)[[:space:]]+(produc[a-z]*|creat[a-z]*|built|generat[a-z]*|publish[a-z]*|compil[a-z]*|success[a-z]*|succeed[a-z]*|pass[a-z]*|resolv[a-z]*|found|imported)/, "", claims)
    gsub(/(^|[^a-z])(no|without)[[:space:]]+((airdc[+][+] core|airdcpp core|core)[[:space:]]+)?compil[a-z]*/, "", claims)
    gsub(/(^|[^a-z])no[[:space:]]+(dist|libairdcpp[.]a)[[:space:]]+((was|is|were)[[:space:]]+)?(produc[a-z]*|creat[a-z]*|built|generat[a-z]*|publish[a-z]*)/, "", claims)
    if (claims ~ /(dist|libairdcpp[.]a)/ &&
        claims ~ /(produc|creat|built|build succeeded|generat|publish)/) bad = "publication/archive production claim"
    if (claims ~ /(airdc[+][+] core|airdcpp core|core)/ &&
        claims ~ /(compil(e|es|ed|ation|ing).*(success|succeed|pass)|success.*compil(e|es|ed|ation|ing))/) bad = "Core compile-success claim"
    excluded = claims ~ /(websocket[+][+]|websocketpp|nlohmann[- ]json|npm|boost([ :.]|::)*system)/
    if (excluded && (section == "## Package resolution" ||
        claims ~ /(resolv|found|imported)/)) bad = "unsupported package resolution claim"
    if (bad) { printf "FAIL: Gate 2 report line %d: %s\n", NR, bad > "/dev/stderr"; exit 1 }
  }
' "$1"
}

# Exercise the real validator: negating errors must not negate a positive
# compile, publication, archive, or package-resolution claim on the same line.
for claim in \
  'No errors: AirDC++ Core compiled successfully and Dist was produced.' \
  'No errors: AirDC++ Core compiled successfully.' \
  'No errors: Dist was produced.' \
  'No errors: libairdcpp.a was produced.' \
  'AirDC++ Core did not compile successfully, but Dist was produced.' \
  'Dist was not produced, but AirDC++ Core compiled successfully.' \
  'No errors: WebSocket++ resolved successfully.'; do
  if printf '%s\n' "$claim" | validate_report_claims /dev/stdin >/dev/null 2>&1; then
    fail "report validator accepted unrelated negation: $claim"
  fi
done
printf '%s\n' \
  'Dist was not produced. libairdcpp.a was never produced.' \
  'AirDC++ Core did not compile successfully.' \
  'No AirDC++ Core compilation succeeded. No libairdcpp.a was produced.' \
  'WebSocket++ was not resolved.' | validate_report_claims /dev/stdin ||
  fail "report validator rejected claim-local negation"
validate_report_claims "$REPORT" || fail "Gate 2 report contract"

. "$ROOT/scripts/lib/configure.sh"
CHECKOUT=$ROOT/Source/airdcpp-core
BUILD=$ROOT/Build/airdcpp-core
SUMMARY=$BUILD/release/airdcpp-configure-summary.txt
INVENTORY=$BUILD/evidence/host-inventory.txt
load_upstream_config "$ROOT/config/upstream.env"
assert_eq "$AIRDCPP_CORE_COMMIT" "55d51ceb817ec006d4ec844d9e3788e1b0ccc352" "configured upstream pin"
assert_eq "$AIRDCPP_CORE_URL" "https://github.com/airdcpp/airdcpp-core.git" "configured upstream origin"
assert_eq "$(git -C "$CHECKOUT" rev-parse HEAD)" "$AIRDCPP_CORE_COMMIT" "upstream commit"
assert_eq "$(git -C "$CHECKOUT" remote get-url --all origin)" "$AIRDCPP_CORE_URL" "upstream origin"
if git -C "$CHECKOUT" symbolic-ref -q HEAD >/dev/null; then fail "upstream must be detached"; fi

# Preserve every existing discovery capture and reuse sidecar, not just the log.
# The release directory and refreshed host inventory are the only mutable outputs.
preserved_evidence() (
  cd "$BUILD"
  paths=$(find . -path ./release -prune -o -path ./evidence/host-inventory.txt -prune -o -type f -print)
  printf '%s\n' "$paths" | LC_ALL=C sort | while IFS= read -r path; do
    [ -n "$path" ] || continue
    shasum -a 256 "$path"
    stat -f '%m:%z:%p' "$path"
  done
)

target_field() {
  awk -v target="$1" -v field="$2" '
    /^target.name=/ { active = ($0 == "target.name=" target) }
    active && index($0, "target." field "=") == 1 {
      count++; value = substr($0, length("target." field "=") + 1)
    }
    END { if (count != 1) exit 1; print value }
  ' "$SUMMARY" || fail "$1: expected one evidence field $2"
}

assert_no_compilation_outputs() {
  artifacts=$(find "$BUILD" -type f \( -name '*.o' -o -name '*.a' -o -name '*.dylib' \))
  while IFS= read -r artifact; do
    [ -n "$artifact" ] || continue
    case "$artifact" in
      */CMakeFiles/*/CompilerIdC/*|*/CMakeFiles/*/CompilerIdCXX/*|*/CMakeFiles/Check*/*) ;;
      *) fail "unexpected compiled artifact: $artifact" ;;
    esac
  done <<EOF
$artifacts
EOF
  ninja_logs=$(find "$BUILD" -type f \( -name '.ninja_log' -o -name '.ninja_deps' \))
  assert_eq "$ninja_logs" "" "no Ninja invocation logs"
  assert_file_absent "$BUILD/release/libairdcpp.a"
  assert_dir_absent "$ROOT/Dist"
  assert_dir_absent "$ROOT/Dependencies"
}

assert_unmodified_capture
assert_no_compilation_outputs
BEFORE_PARENT=$(git -C "$ROOT" status --porcelain=v1 --untracked-files=all)
BEFORE_UPSTREAM=$(git -C "$CHECKOUT" status --porcelain=v1 --untracked-files=all)
BEFORE_SCOPE=$(configure_tree_snapshot "$ROOT")
BEFORE_SOURCE=$(configure_upstream_snapshot "$CHECKOUT")
BEFORE_EVIDENCE=$(preserved_evidence)

output=$("$ROOT/scripts/build" --configure-only)
assert_contains "$output" "no compilation was invoked" "configure-only success"
assert_contains "$output" "reusing preserved unmodified configure status" "first-attempt reuse"
for expected in compiler.id=AppleClang compiler.c.id=AppleClang \
  compiler.cxx.implicit_link_libraries=c++ architecture=arm64 deployment_target=14.0 \
  build_type=Release cxx_standard=20 cxx_standard_required=ON cxx_extensions=OFF \
  build_shared_libs=OFF enable_natpmp=OFF enable_tbb=OFF; do
  assert_line "$SUMMARY" "$expected" "configured policy"
done
assert_line "$SUMMARY" "upstream_source=$CHECKOUT" "configured source"
assert_line "$SUMMARY" "compiler.c.path=$(xcrun --find clang)" "Apple C compiler path"
assert_line "$SUMMARY" "compiler.cxx.path=$(xcrun --find clang++)" "Apple C++ compiler path"
assert_line "$SUMMARY" "sdk=$(xcrun --sdk macosx --show-sdk-path)" "selected SDK"

# Each target must carry its own complete evidence block. RELEASE-only imported
# locations are real locations; an empty generic property must not hide them.
while IFS='|' read -r target formula expected_type; do
  assert_eq "$(target_field "$target" exists)" TRUE "$target exists"
  assert_eq "$(target_field "$target" type)" "$expected_type" "$target type"
  location=$(target_field "$target" imported_location)
  configurations=$(target_field "$target" imported_configurations)
  includes=$(target_field "$target" include_directories)
  interface=$(target_field "$target" interface_libraries)
  if [ "$target" = Threads::Threads ]; then
    assert_eq "$location$configurations$includes$interface" "" "SDK Threads interface"
    continue
  fi
  assert_formula_path "$includes" "$formula"
  case ";$configurations;" in
    *';RELEASE;'*) release_location=$(target_field "$target" imported_location.RELEASE)
      assert_formula_path "$release_location" "$formula" ;;
  esac
  if [ -n "$location" ]; then assert_formula_path "$location" "$formula"; fi
  if [ "$target" = Iconv::Iconv ]; then
    assert_eq "$location$configurations" "" "Iconv interface location policy"
    assert_formula_path "$interface" "$formula"
  else
    if [ -z "$location" ]; then
      assert_contains ";$configurations;" ";RELEASE;" "$target: usable Release library location"
    fi
  fi
done <<'EOF'
BZip2::BZip2|bzip2|UNKNOWN_LIBRARY
ZLIB::ZLIB|zlib|UNKNOWN_LIBRARY
OpenSSL::SSL|openssl@3|UNKNOWN_LIBRARY
OpenSSL::Crypto|openssl@3|UNKNOWN_LIBRARY
miniupnpc::miniupnpc|miniupnpc|UNKNOWN_LIBRARY
leveldb::leveldb|leveldb|SHARED_LIBRARY
maxminddb::maxminddb|libmaxminddb|UNKNOWN_LIBRARY
Boost::thread|boost|SHARED_LIBRARY
Boost::regex|boost|SHARED_LIBRARY
Snappy::snappy|snappy|SHARED_LIBRARY
Threads::Threads||INTERFACE_LIBRARY
Iconv::Iconv|libiconv|INTERFACE_LIBRARY
EOF
assert_eq "$(target_field OpenSSL::SSL interface_libraries)" OpenSSL::Crypto "OpenSSL interface"
assert_contains "$(target_field leveldb::leveldb interface_libraries)" Threads::Threads "LevelDB Threads interface"
assert_contains "$(target_field Boost::thread interface_libraries)" Threads::Threads "Boost Threads interface"
assert_file_present "$BUILD/release/build.ninja"
assert_no_compilation_outputs
assert_eq "$(preserved_evidence)" "$BEFORE_EVIDENCE" "immutable original captures and reuse sidecar"
assert_eq "$(git -C "$ROOT" status --porcelain=v1 --untracked-files=all)" "$BEFORE_PARENT" "parent status"
assert_eq "$(git -C "$CHECKOUT" status --porcelain=v1 --untracked-files=all)" "$BEFORE_UPSTREAM" "upstream status"
assert_eq "$(configure_tree_snapshot "$ROOT")" "$BEFORE_SCOPE" "parent content scope outside Build/airdcpp-core"
assert_eq "$(configure_upstream_snapshot "$CHECKOUT")" "$BEFORE_SOURCE" "upstream content scope"
printf 'PASS: Gate 2 configured pinned AirDC++ Core without compilation\n'
