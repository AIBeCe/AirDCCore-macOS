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

assert_file_absent() { [ ! -e "$1" ] || fail "expected absent path: $1"; }
assert_file_present() { [ -e "$1" ] || fail "expected existing path: $1"; }
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

create_git_race_wrapper() {
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
    '        ln -s "$RACE_OUTSIDE_DIR" "$RACE_CHECKOUT_DIR"' \
    '        exit 0 ;;' \
    '    esac ;;' \
    '  cleanup)' \
    '    case " $* " in' \
    '      *" fetch "*)' \
    '        [ "$1" = "-C" ] || exit 97' \
    '        rm -rf -- "$2"' \
    '        mkdir -p "$2"' \
    '        printf "replacement\\n" > "$2/replacement"' \
    '        exit 1 ;;' \
    '    esac ;;' \
    'esac' \
    'exec "$RACE_REAL_GIT" "$@"' > "$wrapper_dir/git"
  chmod +x "$wrapper_dir/git"
}
