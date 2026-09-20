#!/bin/sh
set -eu
[ "$#" -eq 1 ] || { printf 'build: error: core build requires project root\n' >&2; exit 64; }
PROJECT_ROOT=$1
CHECKOUT=$PROJECT_ROOT/Source/airdcpp-core
BUILD_ROOT=$PROJECT_ROOT/Build/airdcpp-core
CORE_OUTPUT=$BUILD_ROOT/core-release
. "$PROJECT_ROOT/scripts/lib/upstream.sh"
. "$PROJECT_ROOT/scripts/lib/configure.sh"

core_die() { printf 'build: error: core build: %s\n' "$*" >&2; exit 1; }

core_source_check() {
  [ "$(git -C "$CHECKOUT" rev-parse HEAD)" = "$AIRDCPP_CORE_COMMIT" ] || core_die 'upstream HEAD changed'
  [ "$(git -C "$CHECKOUT" remote get-url --all origin)" = "$AIRDCPP_CORE_URL" ] || core_die 'upstream origin changed'
  if git -C "$CHECKOUT" symbolic-ref -q HEAD >/dev/null 2>&1; then core_die 'upstream HEAD is not detached'; fi
  git -C "$CHECKOUT" diff --quiet HEAD -- || core_die 'upstream tracked files changed'
  git -C "$CHECKOUT" diff --cached --quiet -- || core_die 'upstream staged files changed'
  extras=$(git -C "$CHECKOUT" ls-files --others --exclude-standard) || core_die 'failed to inspect upstream untracked files'
  [ -z "$extras" ] || core_die "upstream untracked files changed: $extras"
  ignored=$(git -C "$CHECKOUT" ls-files --others --ignored --exclude-standard) || core_die 'failed to inspect upstream ignored files'
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    case "$path" in
      airdcpp/core/version.inc|airdcpp/core/localization/StringDefs.cpp)
        [ -f "$CHECKOUT/$path" ] && [ ! -L "$CHECKOUT/$path" ] || core_die "generated path is not a regular file: $path" ;;
      *) core_die "unexpected upstream ignored file: $path" ;;
    esac
  done <<EOF
$ignored
EOF
}

core_preserved_snapshot() (
  cd "$BUILD_ROOT" || exit 1
  paths=$(find . -path ./core-release -prune -o -print) || exit 1
  paths=$(printf '%s\n' "$paths" | LC_ALL=C sort) || exit 1
  while IFS= read -r path; do
    [ "$path" != . ] || continue
    if [ -L "$path" ]; then
      link=$(readlink "$path") || exit 1
      printf 'link %s %s\n' "$path" "$link" || exit 1
    elif [ -f "$path" ]; then
      info=$(stat -f '%m:%z:%p' "$path") || exit 1
      digest=$(shasum -a 256 "$path") || exit 1
      printf 'file %s %s %s\n' "$path" "$info" "${digest%% *}" || exit 1
    elif [ -d "$path" ]; then
      printf 'dir %s\n' "$path" || exit 1
    else
      core_die "unexpected preserved-evidence path: $path"
    fi
  done <<EOF
$paths
EOF
)

core_assert_scope() {
  after_parent=$(configure_tree_snapshot "$PROJECT_ROOT") || core_die 'failed to capture final parent snapshot'
  after_preserved=$(core_preserved_snapshot) || core_die 'failed to capture final preserved-evidence snapshot'
  [ "$after_parent" = "$before_parent" ] || core_die 'files outside Build/airdcpp-core changed'
  [ "$after_preserved" = "$before_preserved" ] || core_die 'preserved Gate 2 evidence changed'
  core_source_check
  [ ! -e "$PROJECT_ROOT/Dist" ] && [ ! -L "$PROJECT_ROOT/Dist" ] || core_die 'Dist was created'
  [ ! -e "$PROJECT_ROOT/Dependencies" ] && [ ! -L "$PROJECT_ROOT/Dependencies" ] || core_die 'Dependencies was created'
}

core_build_inputs() {
  inventory=$1
  version=$(sed -n 's/^cmake.version=//p' "$inventory") || core_die 'failed to read CMake version'
  clang=$(sed -n 's/^clang.version=//p' "$inventory") || core_die 'failed to read Apple Clang version'
  sdk=$(sed -n 's/^sdk.version=//p' "$inventory") || core_die 'failed to read SDK version'
  formulae=$(sed -n '/^formula\./p' "$inventory") || core_die 'failed to read formula inventory'
  [ -n "$version" ] && [ -n "$clang" ] && [ -n "$sdk" ] && [ -n "$formulae" ] || core_die 'incomplete build input inventory'
  formula_digest=$(printf '%s\n' "$formulae" | shasum -a 256) || core_die 'failed to hash formula inventory'
  printf 'upstream.commit=%s\ncmake.version=%s\nclang.version=%s\nsdk.version=%s\nformula.inventory.sha256=%s\narchitecture=arm64\ndeployment_target=14.0\nbuild_type=Release\ncxx_standard=20\ncxx_extensions=OFF\nbuild_shared_libs=OFF\nenable_natpmp=OFF\nenable_tbb=OFF\n' \
    "$AIRDCPP_CORE_COMMIT" "$version" "$clang" "$sdk" "${formula_digest%% *}"
}

load_upstream_config "$PROJECT_ROOT/config/upstream.env" || exit 1
assert_supported_host
validate_configure_checkout "$PROJECT_ROOT" "$CHECKOUT" "$AIRDCPP_CORE_COMMIT"
core_source_check
[ ! -e "$PROJECT_ROOT/Dist" ] && [ ! -L "$PROJECT_ROOT/Dist" ] || core_die 'Dist already exists'
[ ! -e "$PROJECT_ROOT/Dependencies" ] && [ ! -L "$PROJECT_ROOT/Dependencies" ] || core_die 'Dependencies already exists'
missing=$(missing_required_formulae)
[ -z "$missing" ] || core_die "missing required Homebrew formulae: $missing"
[ ! -L "$PROJECT_ROOT/Build" ] || core_die 'symlinked Build directory'
[ ! -L "$BUILD_ROOT" ] || core_die 'symlinked Build/airdcpp-core directory'
[ ! -L "$CORE_OUTPUT" ] || core_die 'symlinked core-release directory'
first_build=0
if [ ! -e "$CORE_OUTPUT" ]; then first_build=1; fi
prepare_inventory_output "$CORE_OUTPUT/first-build-state.txt"
[ -d "$CORE_OUTPUT" ] && [ ! -L "$CORE_OUTPUT" ] || core_die 'core-release is not a real directory'
links=$(find "$CORE_OUTPUT" -type l -print) || core_die 'failed to inspect core output symlinks'
[ -z "$links" ] || core_die "symlinked core output path: $links"
if [ "$first_build" -eq 1 ]; then
  printf 'core-release.preexisting=absent\n' > "$CORE_OUTPUT/first-build-state.txt"
else
  [ -f "$CORE_OUTPUT/first-build-state.txt" ] || core_die 'missing first-build state on rerun'
  grep -Fqx 'core-release.preexisting=absent' "$CORE_OUTPUT/first-build-state.txt" || core_die 'invalid first-build state on rerun'
fi
before_parent=$(configure_tree_snapshot "$PROJECT_ROOT") || core_die 'failed to capture initial parent snapshot'
before_preserved=$(core_preserved_snapshot) || core_die 'failed to capture initial preserved-evidence snapshot'
prepare_inventory_output "$CORE_OUTPUT/host-inventory.txt"
write_host_inventory "$CORE_OUTPUT/host-inventory.txt"
inputs=$(core_build_inputs "$CORE_OUTPUT/host-inventory.txt") || core_die 'failed to determine build inputs'
prepare_inventory_output "$CORE_OUTPUT/build-inputs.txt"
if [ "$first_build" -eq 1 ]; then
  printf '%s\n' "$inputs" > "$CORE_OUTPUT/build-inputs.txt"
else
  recorded=$(cat "$CORE_OUTPUT/build-inputs.txt") || core_die 'failed to read previous build inputs'
  [ "$recorded" = "$inputs" ] || core_die 'build inputs changed; preserve or archive core-release before a new attempt'
fi
cmake_prefix_path=$(dependency_cmake_prefix_path) || core_die 'failed to resolve CMake prefixes'
pkg_config_path=$(dependency_pkg_config_path) || core_die 'failed to resolve pkg-config prefixes'
printf 'build: mode=build-core source.commit=%s\n' "$AIRDCPP_CORE_COMMIT"
printf 'build: architecture=arm64 deployment_target=14.0 build_type=Release static=ON C++20 libc++ NAT-PMP=OFF TBB=OFF\n'
config_status=0
run_wrapper_configure "$PROJECT_ROOT" "$CORE_OUTPUT" "$cmake_prefix_path" "$pkg_config_path" || config_status=$?
if [ "$config_status" -ne 0 ]; then
  core_assert_scope
  exit "$config_status"
fi
for field in build-command.txt build.log build-exit-code.txt; do prepare_inventory_output "$CORE_OUTPUT/$field"; done
set -- cmake --build "$CORE_OUTPUT" --target airdcpp --config Release --parallel 2
configure_literal_command "$@" > "$CORE_OUTPUT/build-command.txt"
build_status=0
"$@" > "$CORE_OUTPUT/build.log" 2>&1 || build_status=$?
printf '%s\n' "$build_status" > "$CORE_OUTPUT/build-exit-code.txt"
core_assert_scope
[ "$build_status" -eq 0 ] || core_die "Core build failed (status $build_status); log: $CORE_OUTPUT/build.log"
archive=$CORE_OUTPUT/upstream/libairdcpp.a
[ -f "$archive" ] && [ ! -L "$archive" ] && [ -s "$archive" ] ||
  core_die "Core target exited successfully without a regular nonempty archive: $archive"
printf 'build: core archive candidate=%s\n' "$archive"
