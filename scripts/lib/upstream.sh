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
