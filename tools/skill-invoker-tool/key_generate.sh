#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEY_PATH="${SCRIPT_DIR}/ssh/id_ed25519"
KNOWN_HOSTS="${SCRIPT_DIR}/known_hosts"
KEY_TYPE="ed25519"
COMMENT="ansible-tool"
DEFAULT_PORT="22"
FORCE="false"
TARGET_FILE=""
TARGETS=()

usage() {
  cat <<'USAGE'
Usage:
  ./key_generate.sh [options] user@host[:port] [user@host[:port] ...]
  ./key_generate.sh [options] -f targets.txt

Purpose:
  Generate an SSH key if needed, then copy the public key to one or more SSH
  endpoints. This works for remote machines or containers exposed through SSH
  ports, for example root@10.0.0.2:2222.

Options:
  -k, --key PATH            SSH private key path.
                            Default: ./ssh/id_ed25519 relative to this tool.
  -p, --port PORT           Default SSH port when target has no :port.
                            Default: 22
  -f, --file PATH           Read targets from file. Blank lines and # comments
                            are ignored.
  -c, --comment TEXT        SSH key comment. Default: ansible-tool
  --known-hosts PATH        known_hosts path.
                            Default: ./known_hosts relative to this tool.
  --force                   Recreate key even if it already exists.
  -h, --help                Show help.

Target format:
  user@host
  user@host:port
  host
  host:port

Examples:
  ./key_generate.sh -p 18888 root@71.10.29.116
  ./key_generate.sh root@10.0.0.11:2222 root@10.0.0.12:2223
  ./key_generate.sh -f ./payload/ssh_targets.txt
USAGE
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

parse_target() {
  local target="$1"
  local login="$target"
  local port="$DEFAULT_PORT"

  if [[ "$target" == *:* ]]; then
    login="${target%:*}"
    port="${target##*:}"
  fi

  [[ -n "$login" ]] || die "Invalid target: $target"
  [[ "$port" =~ ^[0-9]+$ ]] || die "Invalid port in target: $target"

  printf '%s\t%s\n' "$login" "$port"
}

target_host() {
  local login="$1"
  printf '%s\n' "${login#*@}"
}

add_targets_from_file() {
  local file="$1"
  [[ -f "$file" ]] || die "Target file not found: $file"

  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | xargs)"
    [[ -n "$line" ]] || continue
    TARGETS+=("$line")
  done < "$file"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -k|--key)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      KEY_PATH="$2"
      shift 2
      ;;
    -p|--port)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      DEFAULT_PORT="$2"
      shift 2
      ;;
    -f|--file)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      TARGET_FILE="$2"
      shift 2
      ;;
    -c|--comment)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      COMMENT="$2"
      shift 2
      ;;
    --known-hosts)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      KNOWN_HOSTS="$2"
      shift 2
      ;;
    --force)
      FORCE="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      while [[ $# -gt 0 ]]; do
        TARGETS+=("$1")
        shift
      done
      ;;
    -*)
      die "Unknown option: $1"
      ;;
    *)
      TARGETS+=("$1")
      shift
      ;;
  esac
done

[[ "$DEFAULT_PORT" =~ ^[0-9]+$ ]] || die "Invalid default port: $DEFAULT_PORT"

need_cmd ssh-keygen
need_cmd ssh-copy-id
need_cmd ssh-keyscan

if [[ -n "$TARGET_FILE" ]]; then
  add_targets_from_file "$TARGET_FILE"
fi

[[ "${#TARGETS[@]}" -gt 0 ]] || {
  usage
  exit 1
}

mkdir -p "$(dirname "$KEY_PATH")" "$(dirname "$KNOWN_HOSTS")"
chmod 700 "$(dirname "$KEY_PATH")"
touch "$KNOWN_HOSTS"

if [[ "$FORCE" == "true" ]]; then
  rm -f "$KEY_PATH" "${KEY_PATH}.pub"
fi

if [[ ! -f "$KEY_PATH" ]]; then
  ssh-keygen -t "$KEY_TYPE" -f "$KEY_PATH" -N "" -C "$COMMENT"
else
  echo "Reuse existing key: $KEY_PATH"
fi

[[ -f "${KEY_PATH}.pub" ]] || die "Public key not found: ${KEY_PATH}.pub"
chmod 600 "$KEY_PATH"
chmod 644 "${KEY_PATH}.pub" "$KNOWN_HOSTS"

for target in "${TARGETS[@]}"; do
  parsed="$(parse_target "$target")"
  login="$(printf '%s' "$parsed" | cut -f1)"
  port="$(printf '%s' "$parsed" | cut -f2)"
  host="$(target_host "$login")"

  echo "==> Trust host key: ${host}:${port}"
  ssh-keygen -R "[${host}]:${port}" -f "$KNOWN_HOSTS" >/dev/null 2>&1 || true
  ssh-keyscan -p "$port" -H "$host" >> "$KNOWN_HOSTS"

  echo "==> Copy public key to ${login}:${port}"
  ssh-copy-id \
    -p "$port" \
    -i "${KEY_PATH}.pub" \
    -o UserKnownHostsFile="$KNOWN_HOSTS" \
    "$login"
done

echo "Done."
echo "Private key: $KEY_PATH"
echo "Known hosts: $KNOWN_HOSTS"
