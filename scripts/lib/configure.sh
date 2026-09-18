#!/bin/sh

configure_die() {
  printf 'build: error: configure discovery: %s\n' "$*" >&2
  exit 1
}

# Scope snapshots deliberately include ignored paths and contents, not merely
# porcelain status (which cannot see generated files or edits to dirty files).
configure_tree_snapshot() (
  cd "$1" || exit 1
  git status --porcelain=v1 --untracked-files=all || exit 1
  find . -name .git -prune -o -path ./Build/airdcpp-core -prune -o \
    -path ./Source/airdcpp-core -prune -o -print | LC_ALL=C sort |
    while IFS= read -r scope_path; do
      if [ -L "$scope_path" ]; then
        printf 'link %s %s\n' "$scope_path" "$(readlink "$scope_path")"
      elif [ -f "$scope_path" ]; then
        printf 'file %s %s %s\n' "$scope_path" \
          "$(stat -f '%m:%z:%p' "$scope_path")" "$(shasum -a 256 "$scope_path" | cut -d ' ' -f1)"
      else
        printf 'path %s\n' "$scope_path"
      fi
    done
)

configure_fingerprint() {
  if [ -L "$1" ]; then printf 'symlink:%s\n' "$(readlink "$1")"
  elif [ -f "$1" ]; then shasum -a 256 "$1" | cut -d ' ' -f1
  elif [ -e "$1" ]; then printf 'non-file\n'
  else printf 'absent\n'; fi
}

configure_upstream_snapshot() (
  git -C "$1" rev-parse HEAD || exit 1
  git -C "$1" remote get-url --all origin || exit 1
  git -C "$1" status --porcelain=v1 --untracked-files=all || exit 1
  git -C "$1" ls-files --others --ignored --exclude-standard || exit 1
  git -C "$1" diff --binary HEAD || exit 1
  for generated in airdcpp/core/version.inc airdcpp/core/localization/StringDefs.cpp; do
    printf '%s=%s\n' "$generated" "$(configure_fingerprint "$1/$generated")"
    [ ! -e "$1/$generated" ] || stat -f '%m:%z:%p' "$1/$generated" || exit 1
  done
)

assert_configure_scope() (
  [ "$(configure_tree_snapshot "$1")" = "$2" ] &&
    [ "$(configure_upstream_snapshot "$1/Source/airdcpp-core")" = "$3" ] ||
    configure_die "configure scope changed outside Build/airdcpp-core; inspect and restore the unexpected changes before retrying"
)

configure_recapture_required() {
  configure_die "archive or remove Build/airdcpp-core/unmodified before recapturing changed inputs"
}

configure_original_inputs() (
  printf 'upstream.commit=%s\n' "$(git -C "$1" rev-parse HEAD)"
  printf 'upstream.cmakelists.sha256=%s\n' "$(configure_fingerprint "$1/CMakeLists.txt")"
  printf 'upstream.pre_status=clean\nupstream.post_status=clean\n'
  for generated in airdcpp/core/version.inc airdcpp/core/localization/StringDefs.cpp; do
    fingerprint=$(configure_fingerprint "$1/$generated")
    printf 'generated.%s.pre=%s\ngenerated.%s.post=%s\n' "$generated" "$fingerprint" "$generated" "$fingerprint"
  done
)

configure_reuse_inputs() (
  configure_original_inputs "$1"
  printf 'cmake.version=%s\n' "$(sed -n 's/^cmake.version=//p' "$2")"
  printf 'formula.inventory.sha256=%s\n' "$(sed -n '/^formula\./p' "$2" | shasum -a 256 | cut -d ' ' -f1)"
  printf 'architecture=arm64\ndeployment_target=14.0\n'
)

# Task2 captured a narrower schema. Never add fields to that historical file:
# derive a one-time sidecar from its cache and the still-preserved inventory.
prepare_unmodified_reuse_metadata() (
  root=$1
  capture=$root/Build/airdcpp-core/unmodified
  inventory=$root/Build/airdcpp-core/evidence/host-inventory.txt
  sidecar=$root/Build/airdcpp-core/evidence/unmodified-reuse-inputs.txt
  [ -e "$capture" ] || return 0
  [ -d "$capture" ] && [ ! -L "$capture" ] || configure_recapture_required
  for field in command.txt inputs.txt exit-code.txt configure.log; do
    [ -f "$capture/$field" ] && [ ! -L "$capture/$field" ] || configure_recapture_required
  done
  grep -Eq '^[0-9]+$' "$capture/exit-code.txt" || configure_recapture_required
  grep -q '^cmake.version=' "$capture/inputs.txt" && return 0
  [ "$(cat "$capture/inputs.txt")" = "$(configure_original_inputs "$root/Source/airdcpp-core")" ] || configure_recapture_required
  if [ -e "$sidecar" ]; then
    [ -f "$sidecar" ] && [ ! -L "$sidecar" ] || configure_recapture_required
    return 0
  fi
  [ -f "$inventory" ] && [ ! -L "$inventory" ] && [ -f "$capture/CMakeCache.txt" ] &&
    [ ! -L "$capture/CMakeCache.txt" ] || configure_recapture_required
  cache_version=
  for component in MAJOR MINOR PATCH; do
    value=$(sed -n "s/^CMAKE_CACHE_${component}_VERSION:INTERNAL=//p" "$capture/CMakeCache.txt")
    case "$value" in ''|*[!0-9]*) configure_recapture_required ;; esac
    cache_version=${cache_version:+$cache_version.}$value
  done
  [ "$(sed -n 's/^cmake.version=//p' "$inventory")" = "$cache_version" ] &&
    grep -qx 'host.arch=arm64' "$inventory" &&
    grep -Eq '^CMAKE_OSX_ARCHITECTURES:[^=]+=arm64$' "$capture/CMakeCache.txt" &&
    grep -Eq '^CMAKE_OSX_DEPLOYMENT_TARGET:[^=]+=14\.0$' "$capture/CMakeCache.txt" || configure_recapture_required
  for formula in $(required_formulae); do
    grep -Eq "^formula\.$formula=[^=]+$" "$inventory" &&
      grep -Eq "^formula\.$formula\.prefix=/[^=]+$" "$inventory" || configure_recapture_required
  done
  prepare_inventory_output "$sidecar"
  temporary=$(mktemp "$sidecar.tmp.XXXXXX") || configure_recapture_required
  configure_reuse_inputs "$root/Source/airdcpp-core" "$inventory" > "$temporary"
  mv "$temporary" "$sidecar" || configure_recapture_required
)

configure_literal_command() (
  for argument do
    printf "'%s' " "$(printf '%s' "$argument" | sed "s/'/'\\\\''/g")"
  done
  printf '\n'
)

capture_unmodified_configure() (
  root=$1; checkout=$2; capture=$3; prefixes=$4; packages=$5
  inputs=$(configure_reuse_inputs "$checkout" "$root/Build/airdcpp-core/evidence/host-inventory.txt")
  if [ -e "$capture" ]; then
    [ -d "$capture" ] && [ ! -L "$capture" ] || configure_recapture_required
    for field in command.txt inputs.txt exit-code.txt configure.log; do
      [ -f "$capture/$field" ] && [ ! -L "$capture/$field" ] || configure_recapture_required
    done
    comparison=$capture/inputs.txt
    if ! grep -q '^cmake.version=' "$comparison"; then
      [ "$(cat "$comparison")" = "$(configure_original_inputs "$checkout")" ] || configure_recapture_required
      comparison=$root/Build/airdcpp-core/evidence/unmodified-reuse-inputs.txt
    fi
    [ -f "$comparison" ] && [ ! -L "$comparison" ] && [ "$(cat "$comparison")" = "$inputs" ] || configure_recapture_required
    printf 'build: reusing preserved unmodified configure status %s\n' "$(cat "$capture/exit-code.txt")"
    return 0
  fi
  prepare_inventory_output "$capture/command.txt"
  stage=$(mktemp -d "$root/Build/airdcpp-core/.unmodified.XXXXXX") || configure_die "failed to reserve capture"
  # Configure into the final directory, but publish all four record files only
  # after the process terminates. An interrupted attempt is intentionally partial.
  set -- cmake -S "$checkout" -B "$capture" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DCMAKE_CXX_STANDARD=20 -DCMAKE_CXX_EXTENSIONS=OFF -DCMAKE_FIND_DEBUG_MODE=ON
  configure_literal_command "$@" | sed "s|$root/||g" > "$stage/command.txt"
  printf '%s\n' "$inputs" > "$stage/inputs.txt"
  status=0
  PKG_CONFIG_PATH=$packages "$@" > "$stage/configure.log" 2>&1 || status=$?
  printf '%s\n' "$status" > "$stage/exit-code.txt"
  for field in command.txt inputs.txt exit-code.txt configure.log; do
    mv "$stage/$field" "$capture/$field" || configure_die "failed to publish capture"
  done
  rmdir "$stage"
  printf 'build: preserved unmodified configure status %s; log: %s/configure.log\n' "$status" "$capture"
)

run_wrapper_configure() (
  root=$1; output=$2; prefixes=$3; packages=$4
  prepare_inventory_output "$output/command.txt"
  [ -d "$output" ] && [ ! -L "$output" ] || configure_die "wrapper output is not a real directory"
  output_links=$(find "$output" -type l -print) || configure_die 'failed to inspect wrapper output'
  [ -z "$output_links" ] || configure_die 'refusing symlinked wrapper output'
  for field in command.txt configure.log cache.txt; do prepare_inventory_output "$output/$field"; done
  bzip2=$(HOMEBREW_NO_AUTO_UPDATE=1 brew --prefix bzip2) || configure_die 'BZip2 prefix unavailable'
  zlib=$(HOMEBREW_NO_AUTO_UPDATE=1 brew --prefix zlib) || configure_die 'ZLIB prefix unavailable'
  openssl=$(HOMEBREW_NO_AUTO_UPDATE=1 brew --prefix openssl@3) || configure_die 'OpenSSL prefix unavailable'
  iconv=$(HOMEBREW_NO_AUTO_UPDATE=1 brew --prefix libiconv) || configure_die 'Iconv prefix unavailable'
  set -- cmake --fresh -S "$root" -B "$output" -G Ninja \
    "-DCMAKE_TOOLCHAIN_FILE=$root/cmake/toolchains/macos-arm64.cmake" \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DCMAKE_CXX_STANDARD=20 -DCMAKE_CXX_EXTENSIONS=OFF \
    -DENABLE_NATPMP=OFF -DENABLE_TBB=OFF "-DCMAKE_PREFIX_PATH=$prefixes" \
    "-DBZIP2_ROOT=$bzip2" "-DZLIB_ROOT=$zlib" "-DOPENSSL_ROOT_DIR=$openssl" \
    "-DIconv_INCLUDE_DIR=$iconv/include" "-DIconv_LIBRARY=$iconv/lib/libiconv.dylib" \
    -DCMAKE_FIND_DEBUG_MODE=ON
  command_tmp=$(mktemp "$output/command.txt.tmp.XXXXXX") || configure_die 'failed to reserve command evidence'
  configure_literal_command "$@" | sed "s|$root/||g; s|'$root'|'.'|g" > "$command_tmp"
  mv "$command_tmp" "$output/command.txt" || configure_die 'failed to publish wrapper command'
  status=0
  PKG_CONFIG_PATH=$packages "$@" > "$output/configure.log" 2>&1 || status=$?
  [ "$status" -eq 0 ] || configure_die "wrapper configure failed (status $status); log: $output/configure.log; correct the discovery inputs and rerun scripts/build --configure-only"
  cmake -N -LA "$output" > "$output/cache.txt" 2>&1 ||
    configure_die "wrapper cache inspection failed; log: $output/cache.txt; inspect the cache and rerun scripts/build --configure-only"
)

required_formulae() {
  printf '%s\n' cmake ninja boost bzip2 zlib openssl@3 miniupnpc \
    leveldb libmaxminddb snappy libiconv pkgconf python@3.14
}

missing_required_formulae() {
  required_formulae | while IFS= read -r formula; do
    HOMEBREW_NO_AUTO_UPDATE=1 brew list --versions "$formula" >/dev/null 2>&1 ||
      printf '%s\n' "$formula"
  done
}

assert_supported_host() {
  [ "$(uname -s)" = Darwin ] || configure_die "macOS is required"
  [ "$(uname -m)" = arm64 ] || configure_die "arm64 host is required"
  clang_output=$(xcrun clang --version 2>/dev/null) ||
    configure_die "xcrun Apple Clang is unavailable"
  clang_version=$(printf '%s\n' "$clang_output" | sed -n '1p')
  case "$clang_version" in
    Apple\ clang\ version*) ;;
    *) configure_die "xcrun did not resolve Apple Clang" ;;
  esac
}

validate_configure_checkout() {
  project_root=$1
  checkout=$2
  expected_commit=$3

  [ ! -L "$checkout" ] || configure_die "refusing symlinked checkout: $checkout"
  [ -e "$checkout/.git" ] && [ ! -L "$checkout/.git" ] ||
    configure_die "checkout is not a Git repository: $checkout"
  load_upstream_config "$project_root/config/upstream.env" ||
    configure_die "invalid upstream configuration"

  checkout_head=$(git -C "$checkout" rev-parse HEAD 2>/dev/null) ||
    configure_die "failed to resolve checkout HEAD"
  [ "$checkout_head" = "$expected_commit" ] ||
    configure_die "checkout HEAD does not match configured commit $expected_commit"
  if git -C "$checkout" symbolic-ref -q HEAD >/dev/null 2>&1; then
    configure_die "checkout HEAD must be detached"
  fi

  checkout_origins=$(git -C "$checkout" remote get-url --all origin 2>/dev/null) ||
    configure_die "checkout has no origin remote"
  [ "$checkout_origins" = "$AIRDCPP_CORE_URL" ] ||
    configure_die "origin URL does not match configured upstream"

  unsafe_changes=$(checkout_changes "$checkout") ||
    configure_die "failed to inspect checkout changes"
  [ -z "$unsafe_changes" ] ||
    configure_die "checkout has unsafe local changes:\n$unsafe_changes"
}

unique_required_formula_prefixes() {
  seen_prefixes='
'
  for formula in $(required_formulae); do
    prefix=$(HOMEBREW_NO_AUTO_UPDATE=1 brew --prefix "$formula" 2>/dev/null) ||
      configure_die "Homebrew prefix unavailable for $formula"
    case "$seen_prefixes" in
      *"
$prefix
"*) continue ;;
    esac
    printf '%s\n' "$prefix"
    seen_prefixes=$seen_prefixes$prefix'
'
  done
}

join_discovery_lines() {
  separator=$1
  joined=
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    joined=${joined:+$joined$separator}$item
  done
  printf '%s\n' "$joined"
}

dependency_cmake_prefix_path() {
  prefix_lines=$(unique_required_formula_prefixes) || return 1
  printf '%s\n' "$prefix_lines" | join_discovery_lines ';'
}

dependency_pkg_config_path() {
  prefix_lines=$(unique_required_formula_prefixes) || return 1
  printf '%s\n' "$prefix_lines" | {
    while IFS= read -r prefix; do
      printf '%s\n' "$prefix/lib/pkgconfig" "$prefix/share/pkgconfig"
    done
  } | join_discovery_lines ':'
}

prepare_inventory_output() {
  requested_output=$1
  [ -n "${PROJECT_ROOT:-}" ] || configure_die "PROJECT_ROOT is required"
  [ -d "$PROJECT_ROOT" ] || configure_die "PROJECT_ROOT is not a directory: $PROJECT_ROOT"
  [ ! -L "$PROJECT_ROOT" ] || configure_die "refusing symlinked PROJECT_ROOT"
  inventory_project_root=${PROJECT_ROOT%/}
  [ -n "$inventory_project_root" ] || inventory_project_root=/
  inventory_root=$inventory_project_root/Build/airdcpp-core
  case "$requested_output" in
    "$inventory_root"/*) ;;
    *) configure_die "inventory output must be inside $inventory_root" ;;
  esac
  inventory_relative=${requested_output#"$inventory_root"/}
  case "/$inventory_relative/" in
    *'/../'*|*'/./'*|*'//'*) configure_die "inventory output contains an unsafe path component" ;;
  esac
  [ -n "$inventory_relative" ] || configure_die "inventory output path is empty"

  inventory_build_dir=$inventory_project_root/Build
  [ ! -L "$inventory_build_dir" ] || configure_die "refusing symlinked Build directory"
  mkdir -p "$inventory_build_dir"
  [ ! -L "$inventory_root" ] || configure_die "refusing symlinked inventory directory"
  mkdir -p "$inventory_root"

  inventory_parent=${requested_output%/*}
  inventory_parent_relative=${inventory_parent#"$inventory_root"}
  inventory_remaining=${inventory_parent_relative#/}
  inventory_current=$inventory_root
  while [ -n "$inventory_remaining" ]; do
    case "$inventory_remaining" in
      */*) inventory_component=${inventory_remaining%%/*}; inventory_remaining=${inventory_remaining#*/} ;;
      *) inventory_component=$inventory_remaining; inventory_remaining= ;;
    esac
    inventory_current=$inventory_current/$inventory_component
    [ ! -L "$inventory_current" ] || configure_die "refusing symlinked inventory path"
    if [ -e "$inventory_current" ]; then
      [ -d "$inventory_current" ] || configure_die "inventory parent is not a directory"
    else
      mkdir "$inventory_current" || configure_die "failed to create inventory directory"
    fi
  done
  [ ! -L "$requested_output" ] || configure_die "refusing symlinked inventory output"
  [ ! -d "$requested_output" ] || configure_die "inventory output is a directory"
}

inventory_path_is_prohibited() {
  inventory_candidate=$1
  for inventory_boundary in /Users /tmp /private/tmp /var/folders /private/var/folders \
    "${HOME:-}" "${TMPDIR:-}"; do
    inventory_boundary=${inventory_boundary%/}
    [ -n "$inventory_boundary" ] && [ "$inventory_boundary" != / ] || continue
    case "$inventory_candidate" in
      "$inventory_boundary"|"$inventory_boundary"/*) return 0 ;;
    esac
  done
  return 1
}

validate_inventory_path_value() {
  inventory_key=$1
  inventory_value=$2
  case "$inventory_value" in
    /*) ;;
    *) configure_die "inventory path is not absolute for $inventory_key" ;;
  esac
  if inventory_path_is_prohibited "$inventory_value"; then
    configure_die "inventory path is prohibited for $inventory_key"
  fi
}

write_host_inventory() {
  output=$1
  prepare_inventory_output "$output"
  assert_supported_host

  sw_vers_output=$(sw_vers) || configure_die "sw_vers failed"
  host_product=$(printf '%s\n' "$sw_vers_output" | sed -n 's/^ProductName:[[:space:]]*//p')
  host_version=$(printf '%s\n' "$sw_vers_output" | sed -n 's/^ProductVersion:[[:space:]]*//p')
  host_build=$(printf '%s\n' "$sw_vers_output" | sed -n 's/^BuildVersion:[[:space:]]*//p')
  host_arch=$(uname -m) || configure_die "host architecture probe failed"

  xcode_output=$(xcodebuild -version) || configure_die "Xcode version probe failed"
  xcode_version=$(printf '%s\n' "$xcode_output" | sed -n 's/^Xcode //p')
  xcode_build=$(printf '%s\n' "$xcode_output" | sed -n 's/^Build version //p')
  clang_output=$(xcrun clang --version) || configure_die "Apple Clang version probe failed"
  clang_version=$(printf '%s\n' "$clang_output" | sed -n '1p')
  clang_path=$(xcrun --find clang) || configure_die "Apple Clang path probe failed"
  clangxx_path=$(xcrun --find clang++) || configure_die "Apple Clang++ path probe failed"
  sdk_path=$(xcrun --sdk macosx --show-sdk-path) || configure_die "macOS SDK path probe failed"
  sdk_version=$(xcrun --sdk macosx --show-sdk-version) || configure_die "macOS SDK version probe failed"
  git_output=$(git --version) || configure_die "Git version probe failed"
  git_version=${git_output#git version }
  python_output=$(python3 --version) || configure_die "Python version probe failed"
  python_version=${python_output#Python }
  homebrew_prefix=$(HOMEBREW_NO_AUTO_UPDATE=1 brew --prefix) ||
    configure_die "Homebrew prefix probe failed"
  homebrew_output=$(HOMEBREW_NO_AUTO_UPDATE=1 brew --version) ||
    configure_die "Homebrew version probe failed"
  homebrew_version=${homebrew_output#Homebrew }
  cmake_output=$(cmake --version) || configure_die "CMake version probe failed"
  cmake_version=${cmake_output#cmake version }
  cmake_version=${cmake_version%%
*}
  ninja_version=$(ninja --version) || configure_die "Ninja version probe failed"

  validate_inventory_path_value clang.path "$clang_path"
  validate_inventory_path_value clangxx.path "$clangxx_path"
  validate_inventory_path_value sdk.path "$sdk_path"
  validate_inventory_path_value homebrew.prefix "$homebrew_prefix"

  formula_inventory=$(
    for formula in $(required_formulae); do
      if formula_output=$(HOMEBREW_NO_AUTO_UPDATE=1 brew list --versions "$formula" 2>/dev/null); then
        formula_version=${formula_output#"$formula "}
      else
        formula_version=absent
      fi
      formula_prefix=$(HOMEBREW_NO_AUTO_UPDATE=1 brew --prefix "$formula" 2>/dev/null) ||
        configure_die "Homebrew prefix unavailable for $formula"
      validate_inventory_path_value "formula.$formula.prefix" "$formula_prefix"
      printf 'formula.%s=%s\n' "$formula" "$formula_version"
      printf 'formula.%s.prefix=%s\n' "$formula" "$formula_prefix"
    done
  ) || return 1

  optional_inventory=$(
    for optional_formula in libnatpmp tbb; do
      if optional_output=$(HOMEBREW_NO_AUTO_UPDATE=1 brew list --versions "$optional_formula" 2>/dev/null); then
        optional_version=${optional_output#"$optional_formula "}
      else
        optional_version=absent
      fi
      printf 'optional.%s=%s\n' "$optional_formula" "$optional_version"
    done
  )

  generated_inventory=$(
    for generated_path in airdcpp/core/version.inc airdcpp/core/localization/StringDefs.cpp; do
      if [ -e "$inventory_project_root/Source/airdcpp-core/$generated_path" ]; then
        generated_state=present
      else
        generated_state=absent
      fi
      printf 'generated.%s=%s\n' "$generated_path" "$generated_state"
    done
  )

  inventory_raw=$(mktemp "$output.raw.XXXXXX") || configure_die "failed to create inventory temporary file"
  inventory_sorted=$(mktemp "$output.sorted.XXXXXX") || {
    rm -f "$inventory_raw"
    configure_die "failed to create sorted inventory temporary file"
  }
  if ! {
    printf 'host.os=%s\n' "$(uname -s)"
    printf 'host.product=%s\n' "$host_product"
    printf 'host.os_version=%s\n' "$host_version"
    printf 'host.os_build=%s\n' "$host_build"
    printf 'host.arch=%s\n' "$host_arch"
    printf 'xcode.version=%s\n' "$xcode_version"
    printf 'xcode.build=%s\n' "$xcode_build"
    printf 'clang.version=%s\n' "$clang_version"
    printf 'clang.path=%s\n' "$clang_path"
    printf 'clangxx.path=%s\n' "$clangxx_path"
    printf 'sdk.path=%s\n' "$sdk_path"
    printf 'sdk.version=%s\n' "$sdk_version"
    printf 'git.version=%s\n' "$git_version"
    printf 'python.version=%s\n' "$python_version"
    printf 'homebrew.prefix=%s\n' "$homebrew_prefix"
    printf 'homebrew.version=%s\n' "$homebrew_version"
    printf 'cmake.version=%s\n' "$cmake_version"
    printf 'ninja.version=%s\n' "$ninja_version"
    printf '%s\n' "$formula_inventory"
    printf '%s\n' "$optional_inventory"
    printf '%s\n' "$generated_inventory"
  } > "$inventory_raw"; then
    rm -f "$inventory_raw" "$inventory_sorted"
    configure_die "failed to collect host inventory"
  fi
  if ! LC_ALL=C sort "$inventory_raw" > "$inventory_sorted"; then
    rm -f "$inventory_raw" "$inventory_sorted"
    configure_die "failed to sort host inventory"
  fi
  rm -f "$inventory_raw"
  mv "$inventory_sorted" "$output" || {
    rm -f "$inventory_sorted"
    configure_die "failed to publish host inventory"
  }
}
