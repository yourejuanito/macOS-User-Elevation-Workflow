#!/bin/sh
# Re-exec under bash if not already
[ -z "$BASH_VERSION" ] && exec /bin/bash "$0" "$@"

# grant-sudo-for-console-user.sh
# Adds the currently logged-in user to /etc/sudoers.d/<username> after explicit SwiftDialog warning/ack.

set -o pipefail

DIALOG="/usr/local/bin/dialog"
LOG_FILE="/var/log/sudoers-grants.log"
AUDIT_DIR="/Library/Management/AdminElevation"
AUDIT_CSV="$AUDIT_DIR/sudoers-audit.csv"

PROTECTED_USERS="root mac_admin administrator Administrator jamf Jamf"

require_root() { [[ $EUID -ne 0 ]] && { echo "Please run as root (sudo)." >&2; exit 1; }; }
log() {
  local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
  { touch "$LOG_FILE" && chmod 644 "$LOG_FILE"; } >/dev/null 2>&1
  echo "[$ts] $*" | tee -a "$LOG_FILE" >/dev/null
  /usr/bin/logger -- "grant-sudo: $*"
}
ensure_audit_store() {
  /bin/mkdir -p "$AUDIT_DIR"
  /usr/sbin/chown root:wheel "$AUDIT_DIR" 2>/dev/null || true
  /bin/chmod 755 "$AUDIT_DIR" 2>/dev/null || true
  if [[ ! -f "$AUDIT_CSV" ]]; then
    echo "timestamp,requested_by,target_user,action,result" > "$AUDIT_CSV"
    /bin/chmod 644 "$AUDIT_CSV" 2>/dev/null || true
  fi
}
audit_append() { echo "$1,$2,$3,$4,$5" >> "$AUDIT_CSV" 2>/dev/null || true; }

console_user_name() {
  /usr/sbin/scutil <<'EOS' | /usr/bin/awk '/Name :/ && $3 != "loginwindow" {print $3}'
open
show State:/Users/ConsoleUser
quit
EOS
}

user_exists() { /usr/bin/id "$1" >/dev/null 2>&1; }
is_protected_user() { local u="$1" p; for p in $PROTECTED_USERS; do [[ "$u" == "$p" ]] && return 0; done; return 1; }

show_error_dialog() {
  local msg="$1"
  if [[ -x "$DIALOG" ]]; then
    "$DIALOG" --title "Action Blocked" --icon "error" --message "$msg" --button1text "OK" --width 560 --height 200 >/dev/null 2>&1
  else
    /usr/bin/osascript -e "display dialog \"$msg\" buttons {\"OK\"} default button 1 with icon stop giving up after 30" >/dev/null 2>&1
  fi
}

require_root

# Discover console user
CONSOLE_USER="$(console_user_name)"
if [[ -z "$CONSOLE_USER" ]]; then
  show_error_dialog "No logged-in console user detected. Please ensure a user is signed in and try again."
  exit 1
fi

if ! user_exists "$CONSOLE_USER"; then
  show_error_dialog "User '$CONSOLE_USER' does not exist on this Mac."
  exit 1
fi

if is_protected_user "$CONSOLE_USER"; then
  show_error_dialog "User '$CONSOLE_USER' is a protected account and cannot be granted sudo via this workflow."
  exit 1
fi

# ---------------- Security Warning Loop ----------------
MAX_ATTEMPTS=3
ATTEMPT=1
ACKNOWLEDGED=""

while [[ $ATTEMPT -le $MAX_ATTEMPTS ]]; do
  tmp_json="$(/usr/bin/mktemp -t dialogsudo)"
  JSON_TMP="${tmp_json}.json"; : > "$JSON_TMP"

  "$DIALOG" \
    --title "Grant Command-Line (sudo) Access" \
    --icon "warning" \
    --width 720 \
    --height 500 \
    --button1text "Grant sudo to $CONSOLE_USER" \
    --button2text "Cancel" \
    --message "You are about to grant **command-line administrative privileges** to the currently logged-in user:\n\n**User:** $CONSOLE_USER\n\n**Security Warning**\n\n   • This allows the user to run commands as root using 'sudo'.\n\n   • Misuse can result in system compromise or data loss.\n\n   • Only proceed if this access is approved and necessary.\n\nAccess can be revoked by removing the file in /etc/sudoers.d/$CONSOLE_USER." \
    --checkbox "I understand the security risks and have verified approvals.,required" \
    --json > "$JSON_TMP"
  DLG_EC=$?

  if [[ $DLG_EC -ne 0 ]]; then
    log "Operator canceled at attempt $ATTEMPT."
    rm -f "$JSON_TMP" 2>/dev/null
    exit 1
  fi

  if /usr/bin/grep -q "true" "$JSON_TMP" 2>/dev/null; then
    ACKNOWLEDGED="yes"
    rm -f "$JSON_TMP" 2>/dev/null
    break
  else
    log "Attempt $ATTEMPT: User did not check acknowledgment box."
    "$DIALOG" --title "Acknowledgment Required" \
      --icon "error" \
      --message "You must acknowledge the security warning before proceeding.\n\nPlease try again." \
      --button1text "Retry" --width 600 --height 200 >/dev/null 2>&1
  fi

  rm -f "$JSON_TMP" 2>/dev/null
  ((ATTEMPT++))
done

if [[ "$ACKNOWLEDGED" != "yes" ]]; then
  log "User failed to acknowledge after $MAX_ATTEMPTS attempts. Aborting."
  exit 1
fi
# --------------------------------------------------------

# Build and validate sudoers entry
SUDOERS_SNIPPET="/etc/sudoers.d/${CONSOLE_USER}"
TMP_SNIPPET="$(/usr/bin/mktemp -t sudoers)"
echo "${CONSOLE_USER} ALL=(ALL) NOPASSWD: ALL" > "${TMP_SNIPPET}"

if ! /usr/sbin/visudo -csf "${TMP_SNIPPET}" >/dev/null 2>&1; then
  rm -f "${TMP_SNIPPET}" 2>/dev/null
  show_error_dialog "visudo validation failed. Aborting without changes."
  log "ERROR: visudo validation failed for '${CONSOLE_USER}'."
  exit 2
fi

/bin/cp "${TMP_SNIPPET}" "${SUDOERS_SNIPPET}"
/bin/chmod 440 "${SUDOERS_SNIPPET}"
/usr/sbin/chown root:wheel "${SUDOERS_SNIPPET}"
rm -f "${TMP_SNIPPET}" 2>/dev/null

ensure_audit_store
TS="$(date '+%Y-%m-%d %H:%M:%S')"
REQ_BY="$(/usr/bin/whoami)"

log "SUCCESS: Granted sudo (NOPASSWD) to '${CONSOLE_USER}' via ${SUDOERS_SNIPPET}."
audit_append "$TS" "$REQ_BY" "$CONSOLE_USER" "grant_sudo" "success"

if [[ -x "$DIALOG" ]]; then
  "$DIALOG" --title "Sudo Access Granted" --icon "success" \
    --message "User '$CONSOLE_USER' now has sudo privileges via:\n$SUDOERS_SNIPPET\n\nTo revoke access, remove this file and run 'visudo -c' to confirm." \
    --button1text "Done" --width 650 --height 260 >/dev/null 2>&1
else
  /usr/bin/osascript -e "display dialog \"User '$CONSOLE_USER' now has sudo via $SUDOERS_SNIPPET.\" buttons {\"OK\"} default button 1 with icon note giving up after 60" >/dev/null 2>&1
fi

exit 0