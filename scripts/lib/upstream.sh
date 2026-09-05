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

cleanup_staging_checkout() {
  if [ -n "${UPDATE_STAGING_DIR:-}" ] && [ -n "${UPDATE_SOURCE_DIR:-}" ] &&
    [ -n "${UPDATE_STAGING_MARKER:-}" ]; then
    case "$UPDATE_STAGING_DIR" in
      "$UPDATE_SOURCE_DIR"/.airdcpp-core.update.*)
        case "$UPDATE_STAGING_MARKER" in
          "$UPDATE_STAGING_DIR"/.airdcpp-core.owner.*)
            [ -f "$UPDATE_STAGING_MARKER" ] && rm -rf -- "$UPDATE_STAGING_DIR" ;;
          *) printf 'update: error: refusing unsafe staging cleanup marker: %s\n' "$UPDATE_STAGING_MARKER" >&2 ;;
        esac ;;
      *) printf 'update: error: refusing unsafe staging cleanup path: %s\n' "$UPDATE_STAGING_DIR" >&2 ;;
    esac
  fi
}

acquire_missing_checkout() {
  UPDATE_SOURCE_DIR=$1
  checkout_dir=$2
  upstream_url=$3
  upstream_commit=$4
  UPDATE_STAGING_DIR=$UPDATE_SOURCE_DIR/.airdcpp-core.update.$$
  UPDATE_STAGING_MARKER=
  [ ! -e "$UPDATE_STAGING_DIR" ] || update_die "staging path already exists: $UPDATE_STAGING_DIR"
  trap cleanup_staging_checkout 0 1 2 15
  mkdir "$UPDATE_STAGING_DIR" || update_die "failed to initialize staging checkout"
  UPDATE_STAGING_MARKER=$(mktemp "$UPDATE_STAGING_DIR/.airdcpp-core.owner.XXXXXX") ||
    update_die "failed to mark staging checkout"
  git init -q "$UPDATE_STAGING_DIR" || update_die "failed to initialize staging checkout"
  git -C "$UPDATE_STAGING_DIR" remote add origin "$upstream_url" || update_die "failed to configure upstream origin"
  git -C "$UPDATE_STAGING_DIR" fetch -q --no-tags --depth=1 origin "$upstream_commit" ||
    update_die "failed to fetch pinned commit $upstream_commit from $upstream_url"
  fetched_commit=$(git -C "$UPDATE_STAGING_DIR" rev-parse FETCH_HEAD) || update_die "failed to resolve fetched commit"
  [ "$fetched_commit" = "$upstream_commit" ] || update_die "fetched commit does not match pin $upstream_commit"
  git -C "$UPDATE_STAGING_DIR" checkout -q --detach "$upstream_commit" || update_die "failed to check out pin"
  [ "$(git -C "$UPDATE_STAGING_DIR" rev-parse HEAD)" = "$upstream_commit" ] || update_die "staged HEAD mismatch"
  [ ! -e "$checkout_dir" ] && [ ! -L "$checkout_dir" ] ||
    update_die "checkout path appeared during acquisition: $checkout_dir"
  mv "$UPDATE_STAGING_DIR" "$checkout_dir" || update_die "failed to publish checkout at $checkout_dir"
  UPDATE_STAGING_DIR=
  UPDATE_STAGING_MARKER=
  trap - 0 1 2 15
  printf 'update: acquired AirDC++ Core at %s\n' "$upstream_commit"
}
