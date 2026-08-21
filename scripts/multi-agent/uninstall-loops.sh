#!/usr/bin/env bash
# uninstall-loops.sh - unload (if loaded) and remove the four launchd
# plists written by install-loops.sh. Idempotent: safe to run even if the
# agents were never loaded, or the plists were never installed.
#
# MA_LAUNCH_AGENTS_DIR overrides the target directory (defaults to
# ~/Library/LaunchAgents); used by tests to avoid ever touching the real
# LaunchAgents directory.
#
# Usage: uninstall-loops.sh [--label-prefix <reverse-dns>]
#
# The prefix must match whatever install-loops.sh used, or this removes
# nothing: the label prefix is the only thing that names the agents.
set -uo pipefail

# The default launchd label prefix for this repo. Must stay in sync with
# install-loops.sh; export-kit.sh rewrites this single anchored line when
# generating a port for another repo, so keep it a plain literal assignment
# on one line.
MA_DEFAULT_LABEL_PREFIX="com.minidumptruck"

: "${MA_LAUNCH_AGENTS_DIR:=$HOME/Library/LaunchAgents}"

# _u_valid_label_prefix <prefix>
# Same rule as install-loops.sh's validator: reverse-DNS-ish, two or more
# dot-separated alphanumeric/hyphen segments. Here it guards the `rm` below —
# a prefix with a slash or a ".." segment must never reach a delete path.
#
# Whole-string match via bash `=~`, not `grep -Eq`: grep anchors ^/$ per line
# and would accept a multiline prefix whose first line looks valid.
_u_valid_label_prefix() {
  local prefix="$1"
  local re='^[A-Za-z0-9][A-Za-z0-9-]*(\.[A-Za-z0-9][A-Za-z0-9-]*)+$'
  [ -n "$prefix" ] || return 1
  [ "${#prefix}" -le 200 ] || return 1
  [[ "$prefix" =~ $re ]]
}

LABEL_PREFIX="$MA_DEFAULT_LABEL_PREFIX"

while [ $# -gt 0 ]; do
  case "$1" in
    --label-prefix)
      shift
      [ $# -gt 0 ] || {
        printf 'ERROR: --label-prefix requires a value\n' >&2
        exit 2
      }
      LABEL_PREFIX="$1"
      shift
      ;;
    --label-prefix=*)
      LABEL_PREFIX="${1#--label-prefix=}"
      shift
      ;;
    -h | --help)
      printf 'Usage: %s [--label-prefix <reverse-dns>]\n' "$(basename "$0")"
      printf '  Default label prefix: %s\n' "$MA_DEFAULT_LABEL_PREFIX"
      exit 0
      ;;
    *)
      printf 'ERROR: unknown argument: %s\n' "$1" >&2
      printf 'Usage: %s [--label-prefix <reverse-dns>]\n' "$(basename "$0")" >&2
      exit 2
      ;;
  esac
done

if ! _u_valid_label_prefix "$LABEL_PREFIX"; then
  printf 'ERROR: invalid --label-prefix: %s\n' "$LABEL_PREFIX" >&2
  printf '       Expected reverse-DNS form: two or more dot-separated segments,\n' >&2
  printf '       each starting with a letter or digit and containing only letters,\n' >&2
  printf '       digits, and hyphens (e.g. com.example.my-repo).\n' >&2
  exit 2
fi

# _u_remove_plist <label>
# Unload (best-effort) and delete one plist.
_u_remove_plist() {
  local label="$1"
  local plist_path="$MA_LAUNCH_AGENTS_DIR/${label}.plist"

  launchctl unload "$plist_path" 2>/dev/null || true
  rm -f -- "$plist_path"
}

_u_remove_plist "$LABEL_PREFIX.builder-loop"
_u_remove_plist "$LABEL_PREFIX.validator-loop"
_u_remove_plist "$LABEL_PREFIX.scribe-loop"
_u_remove_plist "$LABEL_PREFIX.reaper"

printf 'Uninstalled multi-agent launchd agents with prefix %s (unloaded if loaded, plists removed) from %s\n' "$LABEL_PREFIX" "$MA_LAUNCH_AGENTS_DIR"
