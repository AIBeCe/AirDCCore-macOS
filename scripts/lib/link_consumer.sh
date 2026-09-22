#!/bin/sh
set -eu

[ "$#" -eq 1 ] || { printf 'build: error: link consumer requires project root\n' >&2; exit 64; }
PROJECT_ROOT=$1
CHECKOUT=$PROJECT_ROOT/Source/airdcpp-core
BUILD_ROOT=$PROJECT_ROOT/Build/airdcpp-core
CORE_OUTPUT=$BUILD_ROOT/core-release
LINK_ROOT=$BUILD_ROOT/link-interface
STAGE=$LINK_ROOT/stage
CORE_ARCHIVE=$CORE_OUTPUT/upstream/libairdcpp.a

. "$PROJECT_ROOT/scripts/lib/upstream.sh"
. "$PROJECT_ROOT/scripts/lib/configure.sh"

link_die() { printf 'build: error: consumer link: %s\n' "$*" >&2; exit 1; }

link_source_check() {
  [ "$(git -C "$CHECKOUT" rev-parse HEAD)" = "$AIRDCPP_CORE_COMMIT" ] || link_die 'upstream HEAD changed'
  [ "$(git -C "$CHECKOUT" remote get-url --all origin)" = "$AIRDCPP_CORE_URL" ] || link_die 'upstream origin changed'
  git -C "$CHECKOUT" diff --quiet HEAD -- || link_die 'upstream tracked files changed'
  git -C "$CHECKOUT" diff --cached --quiet -- || link_die 'upstream staged files changed'
  extras=$(git -C "$CHECKOUT" ls-files --others --exclude-standard) || link_die 'failed to inspect upstream files'
  [ -z "$extras" ] || link_die "upstream untracked files changed: $extras"
  ignored=$(git -C "$CHECKOUT" ls-files --others --ignored --exclude-standard) || link_die 'failed to inspect ignored upstream files'
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    case "$path" in
      airdcpp/core/version.inc|airdcpp/core/localization/StringDefs.cpp)
        [ -f "$CHECKOUT/$path" ] && [ ! -L "$CHECKOUT/$path" ] || link_die "generated path is not a regular file: $path" ;;
      *) link_die "unexpected upstream ignored file: $path" ;;
    esac
  done <<EOF
$ignored
EOF
}

link_preserved_snapshot() (
  cd "$BUILD_ROOT" || exit 1
  paths=$(find . -path ./link-interface -prune -o -print) || exit 1
  paths=$(printf '%s\n' "$paths" | LC_ALL=C sort) || exit 1
  while IFS= read -r path; do
    [ "$path" != . ] || continue
    if [ -L "$path" ]; then
      target=$(readlink "$path") || exit 1
      printf 'link %s %s\n' "$path" "$target" || exit 1
    elif [ -f "$path" ]; then
      info=$(stat -f '%m:%z:%p' "$path") || exit 1
      digest=$(shasum -a 256 "$path") || exit 1
      printf 'file %s %s %s\n' "$path" "$info" "${digest%% *}" || exit 1
    elif [ -d "$path" ]; then
      printf 'dir %s\n' "$path" || exit 1
    else
      exit 1
    fi
  done <<EOF
$paths
EOF
)

link_assert_scope() {
  after_parent=$(configure_tree_snapshot "$PROJECT_ROOT") || link_die 'failed to capture final parent snapshot'
  after_preserved=$(link_preserved_snapshot) || link_die 'failed to capture final preserved-evidence snapshot'
  [ "$after_parent" = "$before_parent" ] || link_die 'files outside Build/airdcpp-core changed'
  [ "$after_preserved" = "$before_preserved" ] || link_die 'preserved Gate 2/Core evidence changed'
  link_source_check
  [ ! -e "$PROJECT_ROOT/Dist" ] && [ ! -L "$PROJECT_ROOT/Dist" ] || link_die 'Dist was created'
  [ ! -e "$PROJECT_ROOT/Dependencies" ] && [ ! -L "$PROJECT_ROOT/Dependencies" ] || link_die 'Dependencies was created'
}

link_required_evidence='build-inputs.txt build-exit-code.txt archive-members.tsv archive-symbols.txt archive-strings.txt archive-ar-table.txt archive-sha256.txt'
link_case_fields='configure-command.txt configure.log configure-exit-code.txt build-command.txt build.log build-exit-code.txt'

link_validate_attempt() {
  record=$1
  for field in $link_case_fields sha256.txt; do
    [ -f "$record/$field" ] && [ ! -L "$record/$field" ] || link_die "attempt is incomplete: $record/$field"
  done
  entries=$(find "$record" -mindepth 1 -maxdepth 1 -print | LC_ALL=C sort) || link_die "failed to inspect attempt: $record"
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    case " $link_case_fields sha256.txt " in
      *" ${entry##*/} "*) ;;
      *) link_die "attempt contains an unexpected path: $entry" ;;
    esac
  done <<EOF
$entries
EOF
  (cd "$record" && shasum -a 256 -c sha256.txt >/dev/null) || link_die "attempt digest changed: $record"
}

link_preserve_case() {
  case_root=$1
  present=0
  for field in $link_case_fields; do [ -e "$case_root/$field" ] && present=1; done
  [ "$present" -eq 1 ] || return 0
  for field in $link_case_fields; do
    [ -f "$case_root/$field" ] && [ ! -L "$case_root/$field" ] || link_die "previous case is incomplete: $case_root/$field"
  done
  attempts=$case_root/attempts
  if [ -e "$attempts" ]; then
    [ -d "$attempts" ] && [ ! -L "$attempts" ] || link_die "attempts is not a real directory: $attempts"
  else
    mkdir "$attempts" || link_die 'failed to create attempts directory'
  fi
  previous=$(find "$attempts" -mindepth 1 -maxdepth 1 -print | LC_ALL=C sort) || link_die 'failed to inspect attempts'
  next=1
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    attempt_expected=$(printf '%04d' "$next")
    [ "${path##*/}" = "$attempt_expected" ] && [ -d "$path" ] && [ ! -L "$path" ] || link_die "attempts contains an unexpected path: $path"
    link_validate_attempt "$path"
    next=$((next + 1))
  done <<EOF
$previous
EOF
  destination=$attempts/$(printf '%04d' "$next")
  temporary=$(mktemp -d "$attempts/.attempt.XXXXXX") || link_die 'failed to stage previous attempt'
  for field in $link_case_fields; do cp "$case_root/$field" "$temporary/$field" || link_die "failed to preserve $field"; done
  (cd "$temporary" && for field in $link_case_fields; do shasum -a 256 "$field"; done > sha256.txt) || link_die 'failed to hash previous attempt'
  link_validate_attempt "$temporary"
  mv "$temporary" "$destination" || link_die 'failed to publish previous attempt'
}

link_stage_inputs() {
  temporary=$(mktemp -d "$LINK_ROOT/.stage.XXXXXX") || link_die 'failed to reserve staged input tree'
  mkdir -p "$temporary/include" "$temporary/lib" || link_die 'failed to create staged input tree'
  headers=$(find "$CHECKOUT/airdcpp" -path "$CHECKOUT/airdcpp/modules" -prune -o -type f \( -name '*.h' -o -name '*.inc' \) -print | LC_ALL=C sort) || link_die 'failed to enumerate public headers'
  [ -n "$headers" ] || link_die 'no public headers were found'
  while IFS= read -r source; do
    [ -f "$source" ] && [ ! -L "$source" ] || link_die "header is not a regular file: $source"
    relative=${source#"$CHECKOUT/"}
    destination=$temporary/include/$relative
    mkdir -p "${destination%/*}" || link_die "failed to stage header directory: $relative"
    cp "$source" "$destination" || link_die "failed to stage header: $relative"
  done <<EOF
$headers
EOF
  cp "$CORE_ARCHIVE" "$temporary/lib/libairdcpp.a" || link_die 'failed to stage Core archive'
  header_manifest_tmp=$(mktemp "$LINK_ROOT/.headers.XXXXXX") || link_die 'failed to reserve header manifest'
  (cd "$temporary/include" && find . -type f -print | LC_ALL=C sort | while IFS= read -r path; do shasum -a 256 "$path"; done) > "$header_manifest_tmp" || link_die 'failed to hash staged headers'
  [ -s "$header_manifest_tmp" ] || link_die 'staged header manifest is empty'
  [ ! -e "$STAGE" ] || rm -rf -- "$STAGE"
  mv "$temporary" "$STAGE" || link_die 'failed to publish staged input tree'
  mv "$header_manifest_tmp" "$LINK_ROOT/header-manifest.sha256" || link_die 'failed to publish header manifest'
}

link_candidate_items='BZip2 ZLIB OpenSSLSSL OpenSSLCrypto miniupnpc leveldb maxminddb BoostThread BoostRegex Snappy Threads Iconv'

link_csv_without() {
  source_items=$1
  omitted=$2
  result=
  old_ifs=$IFS
  IFS=,
  for item in $source_items; do
    [ "$item" = "$omitted" ] || result=${result:+$result,}$item
  done
  IFS=$old_ifs
  [ -n "$result" ] || result=none
  printf '%s\n' "$result"
}

link_items_csv() {
  result=
  for item in $*; do result=${result:+$result,}$item; done
  [ -n "$result" ] || result=none
  printf '%s\n' "$result"
}

link_run_case() {
  case_root=$1
  link_items=$2
  case_expectation=$3
  if [ -e "$case_root" ]; then [ -d "$case_root" ] && [ ! -L "$case_root" ] || link_die "case is not a real directory: $case_root"; else mkdir "$case_root"; fi
  link_preserve_case "$case_root"
  [ ! -e "$case_root/build" ] || rm -rf -- "$case_root/build"
  set -- cmake -S "$PROJECT_ROOT/smoke-test" -B "$case_root/build" -G Ninja \
    "-DCMAKE_MODULE_PATH=$PROJECT_ROOT/cmake/modules" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_CXX_STANDARD=20 \
    -DCMAKE_CXX_EXTENSIONS=OFF "-DAIRDCCORE_INCLUDE_DIR=$STAGE/include" \
    "-DAIRDCCORE_LIBRARY=$STAGE/lib/libairdcpp.a" \
    "-DAIRDCCORE_MODULE_DIR=$PROJECT_ROOT/cmake/modules" \
    "-DAIRDCCORE_SYSTEM_ICONV_LIBRARY=$system_iconv_library" \
    "-DAIRDCCORE_TEST_LINK_ITEMS=$link_items" "-DCMAKE_PREFIX_PATH=$cmake_prefix_path" \
    "-DBZIP2_ROOT=$bzip2_prefix" "-DZLIB_ROOT=$zlib_prefix" \
    "-DOPENSSL_ROOT_DIR=$openssl_prefix"
  configure_literal_command "$@" > "$case_root/configure-command.txt"
  configure_status=0
  PKG_CONFIG_PATH=$pkg_config_path "$@" > "$case_root/configure.log" 2>&1 || configure_status=$?
  printf '%s\n' "$configure_status" > "$case_root/configure-exit-code.txt"
  set -- cmake --build "$case_root/build" --verbose
  configure_literal_command "$@" > "$case_root/build-command.txt"
  build_status=0
  if [ "$configure_status" -eq 0 ]; then "$@" > "$case_root/build.log" 2>&1 || build_status=$?; else : > "$case_root/build.log"; build_status=125; fi
  printf '%s\n' "$build_status" > "$case_root/build-exit-code.txt"
  link_assert_scope
  [ "$configure_status" -eq 0 ] || link_die "consumer configure failed for ${case_root##*/} (status $configure_status); log: $case_root/configure.log"
  LINK_CASE_BUILD_STATUS=$build_status
  case "$case_expectation" in
    unresolved)
      [ "$build_status" -ne 0 ] || link_die "${case_root##*/} unexpectedly linked"
      grep -q 'Undefined symbols' "$case_root/build.log" || link_die "${case_root##*/} did not fail with unresolved symbols" ;;
    success)
      [ "$build_status" -eq 0 ] || link_die "${case_root##*/} link failed (status $build_status); log: $case_root/build.log" ;;
    classify)
      if [ "$build_status" -ne 0 ]; then
        grep -q 'Undefined symbols' "$case_root/build.log" || link_die "${case_root##*/} failed for a reason other than unresolved symbols"
      fi ;;
    *) link_die "unsupported case expectation: $case_expectation" ;;
  esac
}

link_prepare_file() {
  output=$1
  [ ! -L "$output" ] || link_die "refusing symlinked evidence file: $output"
  [ ! -e "$output" ] || [ -f "$output" ] || link_die "evidence path is not a regular file: $output"
  [ -d "${output%/*}" ] && [ ! -L "${output%/*}" ] || link_die "evidence parent is not a real directory: ${output%/*}"
  : > "$output" || link_die "failed to prepare evidence file: $output"
}

link_capture_final_evidence() {
  executable=$LINK_ROOT/full/airdcpp-smoke
  built_executable=$LINK_ROOT/full/build/airdcpp-smoke
  [ -f "$built_executable" ] && [ ! -L "$built_executable" ] || link_die 'successful full link did not produce a regular executable'
  [ ! -L "$executable" ] || link_die 'refusing symlinked published consumer executable'
  cp "$built_executable" "$executable" || link_die 'failed to publish consumer executable'

  link_command=$LINK_ROOT/link-command.raw.txt
  link_prepare_file "$link_command"
  command_line=$(sed -nE '/(^|[[:space:]])([^[:space:]]*\/)?(clang\+\+|c\+\+)([[:space:]]|$).*airdcpp-smoke/p' "$LINK_ROOT/full/build.log" | tail -n 1) || link_die 'failed to inspect verbose full-link output'
  [ -n "$command_line" ] || link_die 'verbose full-link output did not contain an Apple Clang link command'
  printf '%s\n' "$command_line" > "$link_command"

  core_undefined=$LINK_ROOT/core-undefined.txt
  link_prepare_file "$core_undefined"
  undefined_tmp=$(mktemp "$LINK_ROOT/.undefined.XXXXXX") || link_die 'failed to reserve undefined-symbol evidence'
  xcrun nm -u "$CORE_ARCHIVE" > "$undefined_tmp" 2>&1 || link_die 'failed to inspect Core undefined symbols'
  LC_ALL=C sort -u "$undefined_tmp" > "$core_undefined" || link_die 'failed to normalize Core undefined symbols'
  rm -f "$undefined_tmp"

  binary_file=$LINK_ROOT/binary-file.txt
  binary_arch=$LINK_ROOT/binary-arch.txt
  load_commands=$LINK_ROOT/otool-load-commands.txt
  for output in "$binary_file" "$binary_arch" "$load_commands"; do link_prepare_file "$output"; done
  /usr/bin/file -b "$executable" > "$binary_file" || link_die 'failed to inspect consumer file type'
  /usr/bin/lipo -archs "$executable" > "$binary_arch" || link_die 'failed to inspect consumer architecture'
  /usr/bin/otool -L "$executable" > "$load_commands" || link_die 'failed to inspect consumer load commands'
  grep -Fqx 'arm64' "$binary_arch" || link_die 'consumer executable is not exactly arm64'

  run_root=$LINK_ROOT/run
  if [ -e "$run_root" ]; then [ -d "$run_root" ] && [ ! -L "$run_root" ] || link_die 'run evidence is not a real directory'; else mkdir "$run_root"; fi
  for output in stdout.txt stderr.txt exit-code.txt; do link_prepare_file "$run_root/$output"; done
  run_status=0
  "$executable" > "$run_root/stdout.txt" 2> "$run_root/stderr.txt" || run_status=$?
  printf '%s\n' "$run_status" > "$run_root/exit-code.txt"
  [ "$run_status" -eq 0 ] || link_die "consumer execution failed (status $run_status)"
  [ ! -s "$run_root/stderr.txt" ] || link_die 'consumer wrote to stderr'
  [ "$(wc -l < "$run_root/stdout.txt" | tr -d ' ')" = 1 ] && grep -Eq '^AirDC\+\+ Core .+$' "$run_root/stdout.txt" || link_die 'consumer stdout does not match its contract'

  strings_output=$(mktemp "$LINK_ROOT/.strings.XXXXXX") || link_die 'failed to reserve strings inspection'
  /usr/bin/strings "$executable" > "$strings_output" || link_die 'failed to inspect consumer strings'
  load_command_body=$(mktemp "$LINK_ROOT/.load-commands.XXXXXX") || link_die 'failed to reserve load-command inspection'
  sed '1d' "$load_commands" > "$load_command_body" || link_die 'failed to isolate Mach-O load commands'
  if grep -Fq "$PROJECT_ROOT" "$strings_output" || grep -Fq "$HOME/" "$strings_output" || grep -Fq "$PROJECT_ROOT" "$load_command_body" || grep -Fq "$HOME/" "$load_command_body"; then
    link_die 'consumer executable or load commands leak a worktree or user-home path'
  fi
  rm -f "$strings_output" "$load_command_body"

  python3 "$PROJECT_ROOT/scripts/lib/normalize_link_evidence.py" \
    --project-root "$PROJECT_ROOT" --command "$link_command" \
    --omissions "$LINK_ROOT/omission-results.tsv" --output "$LINK_ROOT/link-interface.tsv" ||
    link_die 'failed to normalize final link evidence'
}

load_upstream_config "$PROJECT_ROOT/config/upstream.env" || exit 1
assert_supported_host
[ ! -L "$PROJECT_ROOT/Source" ] || link_die 'symlinked Source directory'
[ ! -L "$PROJECT_ROOT/Build" ] || link_die 'symlinked Build directory'
[ ! -L "$BUILD_ROOT" ] || link_die 'symlinked Build/airdcpp-core directory'
validate_configure_checkout "$PROJECT_ROOT" "$CHECKOUT" "$AIRDCPP_CORE_COMMIT"
link_source_check
[ ! -e "$PROJECT_ROOT/Dist" ] && [ ! -L "$PROJECT_ROOT/Dist" ] || link_die 'Dist already exists'
[ ! -e "$PROJECT_ROOT/Dependencies" ] && [ ! -L "$PROJECT_ROOT/Dependencies" ] || link_die 'Dependencies already exists'
[ -d "$CORE_OUTPUT" ] && [ ! -L "$CORE_OUTPUT" ] || link_die 'missing Gate 3 core-release directory'
for field in $link_required_evidence; do [ -f "$CORE_OUTPUT/$field" ] && [ ! -L "$CORE_OUTPUT/$field" ] || link_die "missing Gate 3 evidence: $field"; done
[ -f "$CORE_ARCHIVE" ] && [ ! -L "$CORE_ARCHIVE" ] && [ -s "$CORE_ARCHIVE" ] || link_die 'missing Gate 3 archive'
grep -Fqx '0' "$CORE_OUTPUT/build-exit-code.txt" || link_die 'Gate 3 build did not succeed'
grep -Fqx "upstream.commit=$AIRDCPP_CORE_COMMIT" "$CORE_OUTPUT/build-inputs.txt" || link_die 'Gate 3 upstream commit differs from configured pin'
grep -Fqx 'source.file_prefix_map=airdcpp-core' "$CORE_OUTPUT/build-inputs.txt" || link_die 'Gate 3 source prefix-map policy is missing'

inspection=$(mktemp -d /private/tmp/airdc-core-link-inspect.XXXXXX) || link_die 'failed to reserve archive inspection'
trap 'rm -rf -- "$inspection"' 0 1 2 15
python3 "$PROJECT_ROOT/scripts/lib/inspect_core_archive.py" "$CORE_ARCHIVE" "$inspection/archive-members.tsv" "$inspection/archive-symbols.txt" >/dev/null 2>&1 || link_die 'archive member report differs'
/usr/bin/strings "$CORE_ARCHIVE" > "$inspection/archive-strings.txt" || link_die 'archive string inspection failed'
/usr/bin/ar -t "$CORE_ARCHIVE" > "$inspection/archive-ar-table.txt" || link_die 'archive table inspection failed'
(cd "$CORE_OUTPUT" && shasum -a 256 upstream/libairdcpp.a) > "$inspection/archive-sha256.txt" || link_die 'archive hash inspection failed'
cmp -s "$inspection/archive-members.tsv" "$CORE_OUTPUT/archive-members.tsv" || link_die 'archive member report differs'
cmp -s "$inspection/archive-symbols.txt" "$CORE_OUTPUT/archive-symbols.txt" || link_die 'archive symbol report differs'
cmp -s "$inspection/archive-strings.txt" "$CORE_OUTPUT/archive-strings.txt" || link_die 'archive string report differs'
cmp -s "$inspection/archive-ar-table.txt" "$CORE_OUTPUT/archive-ar-table.txt" || link_die 'archive table report differs'
cmp -s "$inspection/archive-sha256.txt" "$CORE_OUTPUT/archive-sha256.txt" || link_die 'archive hash report differs'
if grep -F "$PROJECT_ROOT" "$inspection/archive-strings.txt" >/dev/null 2>&1 ||
    { [ -n "${HOME:-}" ] && grep -F "$HOME/" "$inspection/archive-strings.txt" >/dev/null 2>&1; } ||
    grep -Eq '/(Source|Build)/' "$inspection/archive-strings.txt"; then
  link_die 'Gate 3 archive contains an absolute home, Source, or Build path'
fi

if [ -e "$LINK_ROOT" ]; then
  [ -d "$LINK_ROOT" ] && [ ! -L "$LINK_ROOT" ] || link_die 'symlinked link-interface directory'
  links=$(find "$LINK_ROOT" -type l -print) || link_die 'failed to inspect link-interface paths'
  [ -z "$links" ] || link_die "symlinked link-interface path: $links"
else
  mkdir "$LINK_ROOT" || link_die 'failed to create link-interface directory'
fi

before_parent=$(configure_tree_snapshot "$PROJECT_ROOT") || link_die 'failed to capture initial parent snapshot'
before_preserved=$(link_preserved_snapshot) || link_die 'failed to capture initial preserved-evidence snapshot'
missing=$(missing_required_formulae)
[ -z "$missing" ] || link_die "missing required Homebrew formulae: $missing"
cmake_prefix_path=$(dependency_cmake_prefix_path) || link_die 'failed to resolve CMake dependency prefixes'
pkg_config_path=$(dependency_pkg_config_path) || link_die 'failed to resolve pkg-config dependency prefixes'
bzip2_prefix=$(HOMEBREW_NO_AUTO_UPDATE=1 brew --prefix bzip2) || link_die 'BZip2 prefix unavailable'
zlib_prefix=$(HOMEBREW_NO_AUTO_UPDATE=1 brew --prefix zlib) || link_die 'ZLIB prefix unavailable'
openssl_prefix=$(HOMEBREW_NO_AUTO_UPDATE=1 brew --prefix openssl@3) || link_die 'OpenSSL prefix unavailable'
sdk_path=$(xcrun --show-sdk-path) || link_die 'active macOS SDK is unavailable'
sdk_root=$(CDPATH= cd -- "$sdk_path" && pwd -P) || link_die 'failed to resolve active macOS SDK'
system_iconv_alias=$sdk_root/usr/lib/libiconv.tbd
[ -e "$system_iconv_alias" ] || link_die "system Iconv stub is missing: $system_iconv_alias"
system_iconv_library=$(realpath "$system_iconv_alias") || link_die 'failed to resolve system Iconv stub'
[ -f "$system_iconv_library" ] && [ ! -L "$system_iconv_library" ] || link_die "system Iconv stub is not a regular file: $system_iconv_library"
printf 'build: mode=link-consumer source.commit=%s\n' "$AIRDCPP_CORE_COMMIT"
link_stage_inputs
archive_hash=$(shasum -a 256 "$CORE_ARCHIVE"); archive_hash=${archive_hash%% *}
members_hash=$(shasum -a 256 "$CORE_OUTPUT/archive-members.tsv"); members_hash=${members_hash%% *}
headers_hash=$(shasum -a 256 "$LINK_ROOT/header-manifest.sha256"); headers_hash=${headers_hash%% *}
cat > "$LINK_ROOT/input-manifest.txt" <<EOF
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
link_run_case "$LINK_ROOT/core-only" none unresolved

all_items=$(link_items_csv $link_candidate_items)
link_run_case "$LINK_ROOT/full" all success

omissions_root=$LINK_ROOT/omissions
if [ -e "$omissions_root" ]; then [ -d "$omissions_root" ] && [ ! -L "$omissions_root" ] || link_die 'omissions is not a real directory'; else mkdir "$omissions_root"; fi
for pass_root in "$omissions_root/pass-1" "$omissions_root/pass-2"; do
  if [ -e "$pass_root" ]; then [ -d "$pass_root" ] && [ ! -L "$pass_root" ] || link_die "omission pass is not a real directory: $pass_root"; else mkdir "$pass_root"; fi
done
omission_tmp=$(mktemp "$LINK_ROOT/.omissions.XXXXXX") || link_die 'failed to reserve omission evidence'
printf 'pass\tordinal\tlogical\tclassification\tbuild_exit\n' > "$omission_tmp"
required_items=
ordinal=1
for logical in $link_candidate_items; do
  selected=$(link_csv_without "$all_items" "$logical")
  link_run_case "$omissions_root/pass-1/$logical" "$selected" classify
  if [ "$LINK_CASE_BUILD_STATUS" -eq 0 ]; then
    classification=transitive
  else
    classification=required
    required_items=${required_items:+$required_items }$logical
  fi
  printf '1\t%s\t%s\t%s\t%s\n' "$ordinal" "$logical" "$classification" "$LINK_CASE_BUILD_STATUS" >> "$omission_tmp"
  ordinal=$((ordinal + 1))
done

reduced_items=$(link_items_csv $required_items)
link_run_case "$LINK_ROOT/full" "$reduced_items" success
ordinal=1
for logical in $required_items; do
  selected=$(link_csv_without "$reduced_items" "$logical")
  link_run_case "$omissions_root/pass-2/$logical" "$selected" classify
  [ "$LINK_CASE_BUILD_STATUS" -ne 0 ] || link_die "fixed-point classification changed when omitting $logical"
  printf '2\t%s\t%s\trequired\t%s\n' "$ordinal" "$logical" "$LINK_CASE_BUILD_STATUS" >> "$omission_tmp"
  ordinal=$((ordinal + 1))
done
mv "$omission_tmp" "$LINK_ROOT/omission-results.tsv" || link_die 'failed to publish omission evidence'

link_capture_final_evidence
link_assert_scope
printf 'build: staged consumer inputs=%s\n' "$STAGE"
printf 'build: fixed-point link items=%s\n' "$reduced_items"
printf 'build: consumer=%s/full/airdcpp-smoke\n' "$LINK_ROOT"
