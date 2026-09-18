#!/bin/sh
set -eu

# Catches configure policy/discovery drift, overwritten first-attempt evidence,
# source mutations, and accidental AirDC++ Core compilation or output publication.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
. "$ROOT/tests/test_helper.sh"
. "$ROOT/scripts/lib/upstream.sh"

[ "${AIRDCCORE_RUN_CONFIGURE_TESTS:-0}" = 1 ] ||
  fail "set AIRDCCORE_RUN_CONFIGURE_TESTS=1 to run the real Gate 2 configure test"

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

assert_formula_path() {
  resolved_path=$1
  resolved_formula=$2
  [ -e "$resolved_path" ] || fail "$resolved_formula: missing resolved path $resolved_path"
  formula_prefix=$(HOMEBREW_NO_AUTO_UPDATE=1 brew --prefix "$resolved_formula")
  assert_line "$INVENTORY" "formula.$resolved_formula.prefix=$formula_prefix" "$resolved_formula inventory prefix"
  physical_prefix=$(CDPATH= cd -- "$formula_prefix" && pwd -P)
  if [ -d "$resolved_path" ]; then
    physical_path=$(CDPATH= cd -- "$resolved_path" && pwd -P)
  else
    physical_path=$(CDPATH= cd -- "$(dirname -- "$resolved_path")" && pwd -P)/$(basename -- "$resolved_path")
  fi
  case "$physical_path" in
    "$physical_prefix"|"$physical_prefix"/*) ;;
    *) fail "$resolved_formula: path outside recorded Homebrew prefix: $resolved_path" ;;
  esac
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

for field in command.txt inputs.txt exit-code.txt configure.log; do
  assert_file_present "$BUILD/unmodified/$field"
done
assert_file_present "$BUILD/evidence/unmodified-reuse-inputs.txt"
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
