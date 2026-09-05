#!/bin/sh

upstream_error() {
  printf 'update: error: upstream config: %s\n' "$*" >&2
  return 1
}

load_upstream_config() {
  config_path=$1
  AIRDCPP_CORE_URL=
  AIRDCPP_CORE_COMMIT=
  seen_url=0
  seen_commit=0

  [ -f "$config_path" ] || { upstream_error "missing file: $config_path"; return 1; }
  while IFS= read -r config_line || [ -n "$config_line" ]; do
    case "$config_line" in
      ''|'#'*) continue ;;
      *=*) config_key=${config_line%%=*}; config_value=${config_line#*=} ;;
      *) upstream_error "malformed line: $config_line"; return 1 ;;
    esac
    case "$config_key" in
      AIRDCPP_CORE_URL)
        [ "$seen_url" -eq 0 ] || { upstream_error "duplicate AIRDCPP_CORE_URL"; return 1; }
        AIRDCPP_CORE_URL=$config_value; seen_url=1 ;;
      AIRDCPP_CORE_COMMIT)
        [ "$seen_commit" -eq 0 ] || { upstream_error "duplicate AIRDCPP_CORE_COMMIT"; return 1; }
        AIRDCPP_CORE_COMMIT=$config_value; seen_commit=1 ;;
      *) upstream_error "unknown key: $config_key"; return 1 ;;
    esac
  done < "$config_path"

  [ "$seen_url" -eq 1 ] || { upstream_error "missing AIRDCPP_CORE_URL"; return 1; }
  [ "$seen_commit" -eq 1 ] || { upstream_error "missing AIRDCPP_CORE_COMMIT"; return 1; }
  case "$AIRDCPP_CORE_URL" in
    https://*|file://*) ;;
    *) upstream_error "AIRDCPP_CORE_URL must use https:// or file://"; return 1 ;;
  esac
  if printf '%s\n' "$AIRDCPP_CORE_URL" | grep -Eq '[[:space:]]'; then
    upstream_error "AIRDCPP_CORE_URL must not contain whitespace"
    return 1
  fi
  printf '%s\n' "$AIRDCPP_CORE_COMMIT" | grep -Eq '^[0-9a-f]{40}$' || {
    upstream_error "AIRDCPP_CORE_COMMIT must be a full lowercase 40-character hexadecimal commit"
    return 1
  }
}

update_die() {
  printf 'update: error: %s\n' "$*" >&2
  exit 1
}

validate_project_layout() {
  project_root=$1
  actual_root=$(git -C "$project_root" rev-parse --show-toplevel 2>/dev/null) ||
    update_die "project root is not a Git repository: $project_root"
  [ "$actual_root" = "$project_root" ] ||
    update_die "script root does not match parent Git root: $project_root"
  mkdir -p "$project_root/Source"
  [ ! -L "$project_root/Source" ] || update_die "refusing symlinked Source directory"
  git -C "$project_root" check-ignore -q -- Source/airdcpp-core/ ||
    update_die "Source/airdcpp-core must be ignored by the parent repository"
}

path_identity() {
  [ ! -L "$1" ] || return 1
  stat -f '%d:%i' "$1" 2>/dev/null
}

owned_checkout_is_current() {
  [ -d "$UPDATE_ACQUISITION_DIR" ] &&
    [ "$(path_identity "$UPDATE_ACQUISITION_DIR")" = "$UPDATE_ACQUISITION_DIR_ID" ] &&
    [ -f "$UPDATE_ACQUISITION_MARKER" ] &&
    [ ! -L "$UPDATE_ACQUISITION_MARKER" ] &&
    [ "$(path_identity "$UPDATE_ACQUISITION_MARKER")" = "$UPDATE_ACQUISITION_MARKER_ID" ]
}

cleanup_owned_checkout() {
  [ "${UPDATE_ACQUISITION_CWD:-0}" = 1 ] || return
  if ! owned_checkout_is_current; then
    printf 'update: error: refusing cleanup because checkout ownership changed: %s\n' \
      "$UPDATE_ACQUISITION_DIR" >&2
    return
  fi

  rm -rf -- ./* ./.[!.]* ./..?*
  if ! rmdir "$UPDATE_ACQUISITION_DIR"; then
    printf 'update: error: leaving validated empty acquisition directory: %s\n' \
      "$UPDATE_ACQUISITION_DIR" >&2
  fi
}

acquire_missing_checkout() {
  UPDATE_SOURCE_DIR=$1
  UPDATE_ACQUISITION_DIR=$2
  upstream_url=$3
  upstream_commit=$4
  UPDATE_ACQUISITION_CWD=0
  mkdir "$UPDATE_ACQUISITION_DIR" ||
    update_die "checkout path appeared during acquisition: $UPDATE_ACQUISITION_DIR"
  cd "$UPDATE_ACQUISITION_DIR" || update_die "failed to enter reserved checkout directory"
  UPDATE_ACQUISITION_CWD=1
  UPDATE_ACQUISITION_MARKER=$(mktemp '.airdcpp-core.owner.XXXXXX') ||
    update_die "failed to mark reserved checkout directory"
  UPDATE_ACQUISITION_DIR_ID=$(path_identity .) || update_die "failed to identify reserved checkout directory"
  UPDATE_ACQUISITION_MARKER_ID=$(path_identity "$UPDATE_ACQUISITION_MARKER") ||
    update_die "failed to identify reserved checkout marker"
  trap cleanup_owned_checkout 0 1 2 15
  git -C . init -q || update_die "failed to initialize checkout"
  owned_checkout_is_current || update_die "checkout path changed during acquisition: $UPDATE_ACQUISITION_DIR"
  git -C . remote add origin "$upstream_url" || update_die "failed to configure upstream origin"
  owned_checkout_is_current || update_die "checkout path changed during acquisition: $UPDATE_ACQUISITION_DIR"
  if ! git -C . fetch -q --no-tags --depth=1 origin "$upstream_commit"; then
    owned_checkout_is_current || update_die "checkout path changed during acquisition: $UPDATE_ACQUISITION_DIR"
    update_die "failed to fetch pinned commit $upstream_commit from $upstream_url"
  fi
  owned_checkout_is_current || update_die "checkout path changed during acquisition: $UPDATE_ACQUISITION_DIR"
  fetched_commit=$(git -C . rev-parse FETCH_HEAD) || update_die "failed to resolve fetched commit"
  [ "$fetched_commit" = "$upstream_commit" ] || update_die "fetched commit does not match pin $upstream_commit"
  git -C . checkout -q --detach "$upstream_commit" || update_die "failed to check out pin"
  owned_checkout_is_current || update_die "checkout path changed during acquisition: $UPDATE_ACQUISITION_DIR"
  [ "$(git -C . rev-parse HEAD)" = "$upstream_commit" ] || update_die "staged HEAD mismatch"
  owned_checkout_is_current || update_die "checkout path changed during acquisition: $UPDATE_ACQUISITION_DIR"
  rm -f -- "$UPDATE_ACQUISITION_MARKER" || update_die "failed to remove acquisition marker"
  UPDATE_ACQUISITION_CWD=0
  trap - 0 1 2 15
  printf 'update: acquired AirDC++ Core at %s\n' "$upstream_commit"
}

checkout_changes() {
  inspected_checkout=$1
  git -C "$inspected_checkout" diff --quiet -- || printf '%s\n' '<modified tracked files>'
  git -C "$inspected_checkout" diff --cached --quiet -- || printf '%s\n' '<staged changes>'
  git -C "$inspected_checkout" ls-files --others --exclude-standard
  git -C "$inspected_checkout" ls-files --others --ignored --exclude-standard |
    while IFS= read -r ignored_path; do
      case "$ignored_path" in
        airdcpp/core/version.inc|airdcpp/core/localization/StringDefs.cpp) ;;
        *) printf '%s\n' "$ignored_path" ;;
      esac
    done
}

validate_checkout_origin() {
  inspected_checkout=$1
  expected_url=$2
  origin_urls=$(git -C "$inspected_checkout" remote get-url --all origin 2>/dev/null) ||
    update_die "checkout has no origin remote"
  [ "$origin_urls" = "$expected_url" ] ||
    update_die "origin URL does not match configured upstream (expected $expected_url)"
}

remove_known_generated_files() {
  inspected_checkout=$1
  rm -f -- "$inspected_checkout/airdcpp/core/version.inc" \
    "$inspected_checkout/airdcpp/core/localization/StringDefs.cpp"
}

update_existing_checkout() {
  checkout_dir=$1
  upstream_url=$2
  upstream_commit=$3
  validate_checkout_origin "$checkout_dir" "$upstream_url"
  unsafe_changes=$(checkout_changes "$checkout_dir")
  [ -z "$unsafe_changes" ] || update_die "checkout has unsafe local changes:\n$unsafe_changes"
  current_commit=$(git -C "$checkout_dir" rev-parse HEAD 2>/dev/null) || update_die "failed to resolve checkout HEAD"

  if [ "$current_commit" = "$upstream_commit" ]; then
    if git -C "$checkout_dir" symbolic-ref -q HEAD >/dev/null; then
      git -C "$checkout_dir" checkout -q --detach "$upstream_commit" || update_die "failed to detach at pin"
      printf 'update: normalized AirDC++ Core to detached HEAD at %s\n' "$upstream_commit"
    else
      printf 'update: AirDC++ Core is already at pinned commit %s; no update required\n' "$upstream_commit"
    fi
    return 0
  fi

  git -C "$checkout_dir" fetch -q --no-tags --depth=1 origin "$upstream_commit" ||
    update_die "failed to fetch pinned commit $upstream_commit from $upstream_url"
  fetched_commit=$(git -C "$checkout_dir" rev-parse FETCH_HEAD 2>/dev/null) || update_die "failed to resolve fetched commit"
  [ "$fetched_commit" = "$upstream_commit" ] || update_die "fetched commit does not match pin $upstream_commit"
  remove_known_generated_files "$checkout_dir"
  git -C "$checkout_dir" checkout -q --detach "$upstream_commit" || update_die "failed to check out pin"
  [ "$(git -C "$checkout_dir" rev-parse HEAD)" = "$upstream_commit" ] || update_die "checkout HEAD mismatch"
  [ -z "$(checkout_changes "$checkout_dir")" ] || update_die "checkout is not clean after update"
  printf 'update: updated AirDC++ Core from %s to %s\n' "$current_commit" "$upstream_commit"
}
