#!/usr/bin/env bash
# install-loops.sh - write (but never load) the three launchd plists that
# drive the poll-based multi-agent queue: builder-loop, validator-loop, and
# reaper. Writing a plist to LaunchAgents does not start anything on its
# own; enabling is a deliberate, manual human step (see the printed
# `launchctl load` commands below).
#
# MA_LAUNCH_AGENTS_DIR overrides the target directory (defaults to
# ~/Library/LaunchAgents); used by tests to avoid ever touching the real
# LaunchAgents directory.
#
# Usage: install-loops.sh [--label-prefix <reverse-dns>]
#
# launchd labels are per-user, not per-repo: two checkouts of this system on
# one Mac that share a label prefix would collide on the same four agents.
# --label-prefix gives a second repo its own namespace. Without the flag the
# prefix is MA_DEFAULT_LABEL_PREFIX below and behavior is unchanged.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# The default launchd label prefix for this repo. export-kit.sh rewrites this
# single anchored line when generating a port for another repo, so keep it a
# plain literal assignment on one line.
MA_DEFAULT_LABEL_PREFIX="com.minidumptruck"

: "${MA_LAUNCH_AGENTS_DIR:=$HOME/Library/LaunchAgents}"
: "${MA_ROOT:=$REPO_ROOT/multi-agent}"

# _i_valid_label_prefix <prefix>
# True (0) iff <prefix> is a reverse-DNS-ish label prefix: two or more
# dot-separated segments, each starting alphanumeric and otherwise limited to
# alphanumerics and hyphens. This is what keeps the prefix safe to splice into
# BOTH a launchd Label and a plist FILENAME: no slash, no space, no leading
# dot, no empty segment (so no ".." path segment can appear), nothing that
# needs quoting or escaping.
#
# The match must be bash's `=~`, not `grep -Eq`: grep anchors ^/$ per LINE, so
# a multiline prefix whose first line looks valid would pass while carrying a
# literal newline into the plist filename. `=~` anchors the whole string and
# its `.` never matches a newline, so an embedded newline is rejected.
_i_valid_label_prefix() {
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

if ! _i_valid_label_prefix "$LABEL_PREFIX"; then
  printf 'ERROR: invalid --label-prefix: %s\n' "$LABEL_PREFIX" >&2
  printf '       Expected reverse-DNS form: two or more dot-separated segments,\n' >&2
  printf '       each starting with a letter or digit and containing only letters,\n' >&2
  printf '       digits, and hyphens (e.g. com.example.my-repo).\n' >&2
  exit 2
fi

mkdir -p "$MA_LAUNCH_AGENTS_DIR"
mkdir -p "$MA_ROOT/logs"
# The scribe lane writes merge-approval pending files here and a human renames
# .pending.md -> .approved.md to authorize a merge; create it up front so the
# scribe-loop's approval scan has a directory to read even before the first
# pending file is written.
mkdir -p "$MA_ROOT/merge-approvals"

# _i_xml_escape <string>
# Print <string> with the XML special characters that matter inside plist
# element text content escaped. Order matters: "&" must be escaped first,
# or the "&" introduced by escaping "<"/">" would itself get re-escaped.
_i_xml_escape() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  printf '%s' "$s"
}

# _i_write_plist <label> <script-path> <interval-seconds>
# Write one launchd plist (unloaded); print its path.
#
# launchd LaunchAgents run with a minimal PATH (/usr/bin:/bin:/usr/sbin:
# /sbin) and no MA_ROOT — neither git/node/npm/npx/claude nor this queue's
# root would resolve under a real `launchctl load`. EnvironmentVariables
# bakes in the installing shell's PATH (captured now, at install time, when
# the operator's shell has the real one) and this script's own
# already-computed MA_ROOT (defense-in-depth alongside queue.sh's
# BASH_SOURCE-derived default).
_i_write_plist() {
  local label="$1" script_path="$2" interval="$3"
  local plist_path="$MA_LAUNCH_AGENTS_DIR/${label}.plist"
  local name="${label#$LABEL_PREFIX.}"
  local path_escaped
  path_escaped=$(_i_xml_escape "$PATH")

  cat >"$plist_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${script_path}</string>
  </array>
  <key>StartInterval</key>
  <integer>${interval}</integer>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>${MA_ROOT}/logs/launchd-${name}.out.log</string>
  <key>StandardErrorPath</key>
  <string>${MA_ROOT}/logs/launchd-${name}.err.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>${path_escaped}</string>
    <key>MA_ROOT</key>
    <string>${MA_ROOT}</string>
  </dict>
</dict>
</plist>
EOF

  printf '%s\n' "$plist_path"
}

BUILDER_PLIST=$(_i_write_plist "$LABEL_PREFIX.builder-loop" "$SCRIPT_DIR/builder-loop.sh" 300)
VALIDATOR_PLIST=$(_i_write_plist "$LABEL_PREFIX.validator-loop" "$SCRIPT_DIR/validator-loop.sh" 300)
SCRIBE_PLIST=$(_i_write_plist "$LABEL_PREFIX.scribe-loop" "$SCRIPT_DIR/scribe-loop.sh" 300)
REAPER_PLIST=$(_i_write_plist "$LABEL_PREFIX.reaper" "$SCRIPT_DIR/reaper.sh" 900)

printf '\n'
printf '=================================================================\n'
printf 'NOT ENABLED — manual step required to load these launchd agents.\n'
printf '=================================================================\n'
printf 'Plists written to: %s\n' "$MA_LAUNCH_AGENTS_DIR"
printf 'Label prefix:      %s\n\n' "$LABEL_PREFIX"
printf 'To enable, run:\n'
printf '  launchctl load %s\n' "$BUILDER_PLIST"
printf '  launchctl load %s\n' "$VALIDATOR_PLIST"
printf '  launchctl load %s\n' "$SCRIBE_PLIST"
printf '  launchctl load %s\n' "$REAPER_PLIST"
printf '\n'
