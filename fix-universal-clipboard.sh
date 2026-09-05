#!/usr/bin/env bash
#
# fix-universal-clipboard - repair Apple Universal Clipboard on macOS
#
# When copy/paste between your iPhone/iPad and your Mac silently stops working,
# it is usually one of three user-level daemons stuck in a bad state on the Mac:
#
#   pboard          the pasteboard (clipboard) server
#   useractivityd   Handoff, which Universal Clipboard is built on
#   sharingd        Continuity (AirDrop, Handoff, Universal Clipboard)
#
# Restarting them clears the stuck state. launchd relaunches all three
# immediately, so there is nothing to turn back on afterwards.
#
# No sudo required. Nothing is installed, and no settings are changed.
#
# Usage:
#   ./fix-universal-clipboard.sh            # diagnose, then restart the daemons
#   ./fix-universal-clipboard.sh --check    # diagnose only, change nothing
#   ./fix-universal-clipboard.sh --no-save  # do not preserve clipboard contents
#   ./fix-universal-clipboard.sh --help
#
# MIT License
#

set -euo pipefail

VERSION="1.0.0"
DAEMONS=(pboard useractivityd sharingd)
HANDOFF_DOMAIN="com.apple.coreservices.useractivityd"

CHECK_ONLY=0
SAVE_CLIPBOARD=1

# --- output helpers -------------------------------------------------------

if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'
  GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'
else
  BOLD=''; DIM=''; RED=''; GREEN=''; YELLOW=''; RESET=''
fi

ok()      { printf '  %sOK%s    %s\n'   "$GREEN"  "$RESET" "$1"; }
warn()    { printf '  %sWARN%s  %s\n'   "$YELLOW" "$RESET" "$1"; }
bad()     { printf '  %sFAIL%s  %s\n'   "$RED"    "$RESET" "$1"; }
info()    { printf '  %s...%s   %s\n'   "$DIM"    "$RESET" "$1"; }
heading() { printf '\n%s%s%s\n' "$BOLD" "$1" "$RESET"; }

usage() {
  cat <<EOF
fix-universal-clipboard $VERSION

Repairs Apple Universal Clipboard (copy on iPhone, paste on Mac) by restarting
the three macOS user daemons it depends on.

USAGE
  $(basename "$0") [OPTIONS]

OPTIONS
  --check      Run the diagnostics only. Changes nothing.
  --no-save    Do not preserve the current clipboard contents.
  -h, --help   Show this help.
  --version    Show the version.

WHAT IT DOES
  Restarts pboard, useractivityd and sharingd. launchd brings all three back
  automatically. No sudo, no installs, no settings changed.

WHAT IT CANNOT DO
  Universal Clipboard needs both devices working. This script only touches the
  Mac. If it does not help, the iPhone side needs a restart, since iOS has no
  way to reset the clipboard on its own.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)     CHECK_ONLY=1 ;;
    --no-save)   SAVE_CLIPBOARD=0 ;;
    -h|--help)   usage; exit 0 ;;
    --version)   echo "$VERSION"; exit 0 ;;
    *)           printf 'Unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script only runs on macOS." >&2
  exit 1
fi

# --- diagnostics ----------------------------------------------------------
# Each check reports on one requirement of Universal Clipboard. Findings are
# advisory: the repair runs regardless, since a stuck daemon can look healthy.

heading "Checking the Mac side"

# Handoff. Universal Clipboard is a Handoff feature, and these two flags are
# what the "AirDrop & Handoff" toggle in System Settings actually writes.
handoff_advertise=$(defaults -currentHost read "$HANDOFF_DOMAIN" ActivityAdvertisingAllowed 2>/dev/null || echo "unset")
handoff_receive=$(defaults -currentHost read "$HANDOFF_DOMAIN" ActivityReceivingAllowed 2>/dev/null || echo "unset")

if [[ "$handoff_advertise" == "1" && "$handoff_receive" == "1" ]]; then
  ok "Handoff is enabled (advertising and receiving)"
else
  bad "Handoff looks disabled (advertising=$handoff_advertise receiving=$handoff_receive)"
  warn "Enable it: System Settings > General > AirDrop & Handoff"
fi

# Bluetooth is used to discover the nearby device.
if system_profiler SPBluetoothDataType 2>/dev/null | grep -q "State: On"; then
  ok "Bluetooth is on"
else
  bad "Bluetooth appears to be off. Universal Clipboard needs it."
fi

# Wi-Fi must be on. The transfer itself runs over AWDL (peer to peer), so the
# two devices do not have to share a network, but the radio has to be up.
wifi_device=$(networksetup -listallhardwareports 2>/dev/null \
  | awk '/Hardware Port: Wi-Fi/{getline; print $2}' | head -1)
wifi_device="${wifi_device:-en0}"

if [[ "$(networksetup -getairportpower "$wifi_device" 2>/dev/null)" == *": On"* ]]; then
  wifi_ip=$(ipconfig getifaddr "$wifi_device" 2>/dev/null || true)
  if [[ -n "$wifi_ip" ]]; then
    ok "Wi-Fi is on and connected ($wifi_device, $wifi_ip)"
  else
    ok "Wi-Fi radio is on ($wifi_device, not joined to a network)"
  fi
else
  bad "Wi-Fi is off. Universal Clipboard needs the Wi-Fi radio on."
fi

# AWDL is the peer-to-peer link that carries the clipboard payload.
if ifconfig awdl0 2>/dev/null | head -1 | grep -q "RUNNING"; then
  ok "awdl0 is up (the peer-to-peer link Continuity uses)"
else
  warn "awdl0 is not running. It usually comes back with the daemons."
fi

# Both devices must be signed in to the same iCloud account.
icloud_account=$(defaults read MobileMeAccounts Accounts 2>/dev/null \
  | awk -F'"' '/AccountID/{print $2; exit}' || true)
if [[ -n "$icloud_account" ]]; then
  ok "Signed in to iCloud as $icloud_account"
  info "The other device must use this same account"
else
  bad "No iCloud account found. Both devices must share one."
fi

heading "Daemon state"
for d in "${DAEMONS[@]}"; do
  pid=$(pgrep -x "$d" 2>/dev/null | head -1 || true)
  if [[ -n "$pid" ]]; then
    ok "$d is running (pid $pid)"
  else
    warn "$d is not running"
  fi
done

if [[ $CHECK_ONLY -eq 1 ]]; then
  heading "Done"
  echo "  Diagnostics only, nothing was changed."
  echo "  Run without --check to restart the daemons."
  exit 0
fi

# --- repair ---------------------------------------------------------------

heading "Restarting the daemons"

# Killing pboard drops whatever is on the clipboard, so stash the plain text
# and put it back afterwards. Styled text, images and files are not preserved.
saved_clipboard=""
clipboard_had_content=0
if [[ $SAVE_CLIPBOARD -eq 1 ]]; then
  saved_clipboard=$(pbpaste 2>/dev/null || true)
  if [[ -n "$saved_clipboard" ]]; then
    clipboard_had_content=1
    info "Saved current clipboard text ($(printf '%s' "$saved_clipboard" | wc -c | tr -d ' ') bytes)"
  fi
fi

before=""
for d in "${DAEMONS[@]}"; do
  before+="$d=$(pgrep -x "$d" 2>/dev/null | head -1 || echo none) "
done
info "PIDs before: ${before% }"

# launchd restarts each of these on demand, so a plain kill is enough. It
# returns non-zero when a daemon is not running, which is not a failure here.
killall "${DAEMONS[@]}" 2>/dev/null || true

# Give launchd a moment to bring them back before reporting.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  sleep 1
  all_up=1
  for d in "${DAEMONS[@]}"; do
    pgrep -x "$d" >/dev/null 2>&1 || all_up=0
  done
  [[ $all_up -eq 1 ]] && break
done

failed=0
for d in "${DAEMONS[@]}"; do
  pid=$(pgrep -x "$d" 2>/dev/null | head -1 || true)
  if [[ -n "$pid" ]]; then
    ok "$d restarted (pid $pid)"
  else
    bad "$d did not come back"
    failed=1
  fi
done

if [[ $clipboard_had_content -eq 1 ]]; then
  printf '%s' "$saved_clipboard" | pbcopy 2>/dev/null || true
  info "Restored clipboard text (formatting and images were not preserved)"
  warn "That restore overwrote the shared clipboard. Copy on the other device"
  warn "again before testing, or run with --no-save."
fi

# --- what to do next ------------------------------------------------------

heading "Now test it"
cat <<'EOF'
  1. On the iPhone or iPad, copy a short piece of plain text.
  2. Copy NOTHING on the Mac in between. There is a single shared clipboard
     and the most recent copy wins, whichever device it came from. Copying
     anything locally silently replaces what the phone sent.
  3. Within two minutes, press Cmd+V on the Mac.
     The clipboard expires on its own, so do not wait longer.

  Test by actually pasting. Do not use `pbpaste` to check: it reads the local
  pasteboard only and does not pull in the remote clipboard, so it will look
  empty even when Universal Clipboard is working.

  Copying an image? Paste it somewhere that accepts images, such as Preview
  via File > New from Clipboard. A destination that only takes text will fall
  back to whatever text is on the clipboard, which looks exactly like failure.

  Still not working? The iPhone side needs attention:
  - Settings > General > AirPlay & Continuity > Handoff: turn it off and on.
  - Keep the device unlocked and nearby while you copy.
  - Restart the iPhone. iOS has no clipboard reset, so a restart is the only
    way to clear its side.
  - Confirm both devices use the same iCloud account.
  - Check Settings > General > VPN & Device Management. A work profile on the
    phone can block the clipboard between devices even on a shared account.
EOF

if [[ $failed -eq 1 ]]; then
  echo
  echo "  Some daemons did not restart. Try again, or reboot the Mac." >&2
  exit 1
fi

exit 0
