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
