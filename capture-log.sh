#!/usr/bin/env bash
#
# capture-log.sh - record what macOS logs while you copy on the other device
#
# Universal Clipboard fails silently: nothing surfaces an error in the UI. This
# captures the unified log from the daemons involved while you copy on the
# iPhone, so the actual failure becomes visible.
#
# Usage:
#   ./capture-log.sh [seconds]     # defaults to 45
#
# While it runs, copy a short piece of plain text on the iPhone, then press
# Cmd+V on the Mac. The log is written to a file it names at the end.
#

set -euo pipefail

DURATION="${1:-45}"
OUT="${TMPDIR:-/tmp}/universal-clipboard-$(date +%Y%m%d-%H%M%S).log"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script only runs on macOS." >&2
  exit 1
fi

PREDICATE='process == "sharingd"
  OR process == "useractivityd"
  OR process == "pboard"
  OR process == "identityservicesd"
  OR subsystem == "com.apple.sharing"
  OR subsystem == "com.apple.coreservices.useractivity"'

echo "Recording for ${DURATION}s into:"
echo "  $OUT"
echo
echo "NOW: copy a short piece of plain text on the iPhone,"
echo "     then press Cmd+V here on the Mac."
echo

# log stream needs a real terminal session to read the unified log.
log stream --predicate "$PREDICATE" --level debug --style compact > "$OUT" 2>&1 &
LOG_PID=$!

# Stop the stream even if this script is interrupted.
trap 'kill "$LOG_PID" 2>/dev/null || true' EXIT INT TERM

for ((i = DURATION; i > 0; i--)); do
  printf '\r  %2ds remaining ' "$i"
  sleep 1
done
printf '\r%*s\r' 30 ''

kill "$LOG_PID" 2>/dev/null || true
wait "$LOG_PID" 2>/dev/null || true
trap - EXIT INT TERM

lines=$(wc -l < "$OUT" | tr -d ' ')
echo "Captured $lines lines."
echo
echo "File: $OUT"

if [[ "$lines" -eq 0 ]]; then
  echo
  echo "Nothing was captured. The unified log needs a real terminal session;"
  echo "run this from Terminal.app or iTerm rather than from an embedded shell."
fi
