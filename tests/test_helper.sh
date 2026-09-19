#!/bin/sh

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  actual=$1
  expected=$2
  label=$3
  [ "$actual" = "$expected" ] || fail "$label: expected [$expected], got [$actual]"
}

assert_contains() {
  haystack=$1
  needle=$2
  label=$3
  case "$haystack" in
    *"$needle"*) ;;
    *) fail "$label: expected output containing [$needle], got [$haystack]" ;;
  esac
}

assert_not_contains() {
  haystack=$1
  needle=$2
  label=$3
  case "$haystack" in
    *"$needle"*) fail "$label: unexpected output containing [$needle]" ;;
  esac
}

assert_dir_absent() { [ ! -d "$1" ] || fail "expected absent directory: $1"; }

assert_line() {
  file=$1
  line=$2
  label=$3
  grep -Fqx -- "$line" "$file" || fail "$label: missing exact line [$line] in $file"
}

assert_file_absent() { [ ! -e "$1" ] || fail "expected absent path: $1"; }
assert_file_present() { [ -e "$1" ] || fail "expected existing path: $1"; }

# Shared by the real Gate 2 acceptance test and hermetic capture/path cases.
assert_unmodified_capture() {
  for field in command.txt inputs.txt exit-code.txt configure.log; do
    assert_file_present "$BUILD/unmodified/$field"
  done
  comparison=$BUILD/unmodified/inputs.txt
  if ! grep -q '^cmake.version=' "$comparison"; then
    original_inputs=$(configure_original_inputs "$CHECKOUT") || fail 'failed to read original capture inputs'
    preserved_inputs=$(cat "$comparison") || fail 'failed to read legacy capture inputs'
    assert_eq "$preserved_inputs" "$original_inputs" 'legacy original capture inputs'
    comparison=$BUILD/evidence/unmodified-reuse-inputs.txt
    assert_file_present "$comparison"
  fi
  reuse_inputs=$(configure_reuse_inputs "$CHECKOUT" "$INVENTORY") || fail 'failed to read capture reuse inputs'
  preserved_inputs=$(cat "$comparison") || fail 'failed to read preserved capture inputs'
  assert_eq "$preserved_inputs" "$reuse_inputs" 'unmodified capture inputs do not match'
}

assert_formula_path() {
  resolved_path=$1
  resolved_formula=$2
  [ -e "$resolved_path" ] || fail "$resolved_formula: missing resolved path $resolved_path"
  formula_prefix=$(HOMEBREW_NO_AUTO_UPDATE=1 brew --prefix "$resolved_formula") || fail "$resolved_formula: failed to read Homebrew prefix"
  assert_line "$INVENTORY" "formula.$resolved_formula.prefix=$formula_prefix" "$resolved_formula inventory prefix"
  physical_prefix=$(CDPATH= cd -- "$formula_prefix" && pwd -P) || fail "$resolved_formula: failed to resolve Homebrew prefix"
  physical_path=$(realpath "$resolved_path") || fail "$resolved_formula: failed to resolve complete path $resolved_path"
  case "$physical_path" in
    "$physical_prefix"|"$physical_prefix"/*) ;;
    *) fail "$resolved_formula: path outside recorded Homebrew prefix: $resolved_path" ;;
  esac
}

new_temp_dir() { mktemp -d "${TMPDIR:-/tmp}/airdc-core-tests.XXXXXX"; }

create_remote_fixture() {
  fixture_root=$1
  mkdir -p "$fixture_root/seed"
  git -C "$fixture_root/seed" init -q
  git -C "$fixture_root/seed" config user.name "AirDCCore Tests"
  git -C "$fixture_root/seed" config user.email "tests@example.invalid"
  git -C "$fixture_root/seed" config commit.gpgsign false
  printf 'pinned\n' > "$fixture_root/seed/state.txt"
  printf '/EN_Example.xml\n/airdcpp/core/version.inc\n/airdcpp/core/localization/StringDefs.cpp\n' \
    > "$fixture_root/seed/.gitignore"
  git -C "$fixture_root/seed" add state.txt .gitignore
  git -C "$fixture_root/seed" commit -q -m "pinned state"
  FIXTURE_PIN=$(git -C "$fixture_root/seed" rev-parse HEAD)
  printf 'later\n' > "$fixture_root/seed/state.txt"
  git -C "$fixture_root/seed" commit -q -am "later state"
  FIXTURE_LATER=$(git -C "$fixture_root/seed" rev-parse HEAD)
  git clone -q --bare "$fixture_root/seed" "$fixture_root/remote.git"
  FIXTURE_URL=file://$fixture_root/remote.git
}

create_case_project() {
  case_root=$1
  repo_root=$2
  fixture_url=$3
  fixture_commit=$4
  mkdir -p "$case_root/config" "$case_root/scripts/lib" "$case_root/Source"
  cp "$repo_root/scripts/update" "$case_root/scripts/update"
  cp "$repo_root/scripts/lib/upstream.sh" "$case_root/scripts/lib/upstream.sh"
  printf '/Source/airdcpp-core/\n' > "$case_root/.gitignore"
  printf 'AIRDCPP_CORE_URL=%s\nAIRDCPP_CORE_COMMIT=%s\n' \
    "$fixture_url" "$fixture_commit" > "$case_root/config/upstream.env"
  git -C "$case_root" init -q
}

create_race_wrappers() {
  wrapper_dir=$1
  mkdir -p "$wrapper_dir"
  printf '%s\n' \
    '#!/bin/sh' \
    'set -eu' \
    'case "${RACE_MODE:-}" in' \
    '  publication)' \
    '    case " $* " in' \
    '      *" checkout "*)' \
    '        "$RACE_REAL_GIT" "$@"' \
    '        rm -rf -- "$RACE_CHECKOUT_DIR"' \
    '        ln -s "$RACE_OUTSIDE_DIR" "$RACE_CHECKOUT_DIR"' \
    '        exit 0 ;;' \
    '    esac ;;' \
    '  cleanup)' \
    '    case " $* " in' \
    '      *" fetch "*)' \
    '        marker=$(find "$PWD" -maxdepth 1 -type f -name ".airdcpp-core.owner.*" -print -quit)' \
    '        [ -n "$marker" ] || exit 98' \
    '        cp "$marker" "$RACE_MARKER_COPY"' \
    '        rm -rf -- "$RACE_CHECKOUT_DIR"' \
    '        mkdir -p "$RACE_CHECKOUT_DIR"' \
    '        cp "$RACE_MARKER_COPY" "$RACE_CHECKOUT_DIR/$(basename "$marker")"' \
    '        printf "replacement\\n" > "$RACE_CHECKOUT_DIR/replacement"' \
    '        "$RACE_REAL_GIT" "$@"' \
    '        exit $? ;;' \
    '    esac ;;' \
    'esac' \
    'exec "$RACE_REAL_GIT" "$@"' > "$wrapper_dir/git"
  chmod +x "$wrapper_dir/git"
}
