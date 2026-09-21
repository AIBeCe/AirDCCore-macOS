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

link_required_evidence='build-inputs.txt build-exit-code.txt archive-members.tsv archive-symbols.txt'
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
    expected=$(printf '%04d' "$next")
    [ "${path##*/}" = "$expected" ] && [ -d "$path" ] && [ ! -L "$path" ] || link_die "attempts contains an unexpected path: $path"
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

link_run_core_only() {
  case_root=$LINK_ROOT/core-only
  if [ -e "$case_root" ]; then [ -d "$case_root" ] && [ ! -L "$case_root" ] || link_die 'core-only is not a real directory'; else mkdir "$case_root"; fi
  link_preserve_case "$case_root"
  [ ! -e "$case_root/build" ] || rm -rf -- "$case_root/build"
  set -- cmake -S "$PROJECT_ROOT/smoke-test" -B "$case_root/build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_CXX_STANDARD=20 \
    -DCMAKE_CXX_EXTENSIONS=OFF "-DAIRDCCORE_INCLUDE_DIR=$STAGE/include" \
    "-DAIRDCCORE_LIBRARY=$STAGE/lib/libairdcpp.a" -DAIRDCCORE_TEST_LINK_ITEMS=fixture
  configure_literal_command "$@" > "$case_root/configure-command.txt"
  configure_status=0
  "$@" > "$case_root/configure.log" 2>&1 || configure_status=$?
  printf '%s\n' "$configure_status" > "$case_root/configure-exit-code.txt"
  set -- cmake --build "$case_root/build" --verbose
  configure_literal_command "$@" > "$case_root/build-command.txt"
  build_status=0
  if [ "$configure_status" -eq 0 ]; then "$@" > "$case_root/build.log" 2>&1 || build_status=$?; else : > "$case_root/build.log"; build_status=125; fi
  printf '%s\n' "$build_status" > "$case_root/build-exit-code.txt"
  link_assert_scope
  [ "$configure_status" -eq 0 ] || link_die "Core-only consumer configure failed (status $configure_status)"
  [ "$build_status" -ne 0 ] || link_die 'Core-only consumer unexpectedly linked without dependencies'
  grep -q 'Undefined symbols' "$case_root/build.log" || link_die 'Core-only consumer did not fail with unresolved symbols'
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

inspection=$(mktemp -d /private/tmp/airdc-core-link-inspect.XXXXXX) || link_die 'failed to reserve archive inspection'
trap 'rm -rf -- "$inspection"' 0 1 2 15
python3 "$PROJECT_ROOT/scripts/lib/inspect_core_archive.py" "$CORE_ARCHIVE" "$inspection/archive-members.tsv" "$inspection/archive-symbols.txt" >/dev/null 2>&1 || link_die 'archive member report differs'
cmp -s "$inspection/archive-members.tsv" "$CORE_OUTPUT/archive-members.tsv" || link_die 'archive member report differs'
cmp -s "$inspection/archive-symbols.txt" "$CORE_OUTPUT/archive-symbols.txt" || link_die 'archive symbol report differs'

if [ -e "$LINK_ROOT" ]; then
  [ -d "$LINK_ROOT" ] && [ ! -L "$LINK_ROOT" ] || link_die 'symlinked link-interface directory'
  links=$(find "$LINK_ROOT" -type l -print) || link_die 'failed to inspect link-interface paths'
  [ -z "$links" ] || link_die "symlinked link-interface path: $links"
else
  mkdir "$LINK_ROOT" || link_die 'failed to create link-interface directory'
fi

before_parent=$(configure_tree_snapshot "$PROJECT_ROOT") || link_die 'failed to capture initial parent snapshot'
before_preserved=$(link_preserved_snapshot) || link_die 'failed to capture initial preserved-evidence snapshot'
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
link_run_core_only
printf 'build: staged consumer inputs=%s\n' "$STAGE"
printf 'build: preserved expected Core-only unresolved-link baseline; dependency closure remains Task 3\n'
