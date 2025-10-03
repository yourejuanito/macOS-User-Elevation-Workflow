#!/bin/bash
#
# This script has been designed to elevate user after appropriate internal approvals. 
# Leveraging osascript and SwiftDialog. Designed for Service desk users to run this once
# they recieve a task this would automate the elevation of the standadrd user to the admin
# macOS group. 
#
# Created by Juan Garcia aka yourejuanito 10/02/2025
#

set -o pipefail

DIALOG="/usr/local/bin/dialog"
LOG_FILE="/var/log/user-elevations.log"
AUDIT_DIR="/Library/Management/AdminElevation"
AUDIT_CSV="$AUDIT_DIR/audit.csv"

# -------------------- Config / Prefill) --------------------
PROTECTED_USERS="administrator Administrator root jamf Jamf"

# Determine sensible default username dynamically (console user if valid)
console_user_name() {
  /usr/sbin/scutil <<'EOS' | /usr/bin/awk '/Name :/ {print $3}'
open
show State:/Users/ConsoleUser
quit
EOS
}
user_exists() { /usr/bin/id "$1" >/dev/null 2>&1; }
user_is_local_real() { local uid; uid="$(/usr/bin/id -u "$1" 2>/dev/null)" || return 1; [[ "$uid" -ge 501 ]]; }
is_protected_user() { local u="$1" p; for p in $PROTECTED_USERS; do [[ "$u" == "$p" ]] && return 0; done; return 1; }

DEFAULT_USERNAME=""
CU="$(console_user_name)"
if [[ -n "$CU" && "$CU" != "loginwindow" ]] && user_exists "$CU" && user_is_local_real "$CU" && ! is_protected_user "$CU"; then
  DEFAULT_USERNAME="$CU"
fi
DEFAULT_INCIDENT=""  # left blank (dynamic)

# -------------------- Helpers --------------------
run_as_console_user_osascript() {
  local script="$1"
  local cu; cu="$(console_user_name)"
  [ -z "$cu" -o "$cu" = "loginwindow" ] && return 1
  local cuid; cuid="$(/usr/bin/id -u "$cu" 2>/dev/null)" || return 1
  if /bin/launchctl asuser "$cuid" /usr/bin/osascript -e "$script" >/dev/null 2>&1; then
    /bin/launchctl asuser "$cuid" /usr/bin/osascript -e "$script"
  else
    /usr/bin/sudo -u "$cu" /usr/bin/osascript -e "$script"
  fi
}
require_root() { [[ $EUID -ne 0 ]] && { echo "Please run as root (sudo)." >&2; exit 1; }; }
abort_dialog() { local msg="$1"; echo "$msg" >&2; /usr/bin/logger -- "elevate-permanent: ABORT: $msg"; exit 1; }
log() {
  local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[$ts] $*"
  { touch "$LOG_FILE" && chmod 644 "$LOG_FILE"; } >/dev/null 2>&1
  echo "[$ts] $*" >> "$LOG_FILE" 2>/dev/null || true
  /usr/bin/logger -- "elevate-permanent: $*"
}
ensure_audit_store() {
  /bin/mkdir -p "$AUDIT_DIR"
  /usr/sbin/chown root:wheel "$AUDIT_DIR" 2>/dev/null || true
  /bin/chmod 755 "$AUDIT_DIR" 2>/dev/null || true
  if [[ ! -f "$AUDIT_CSV" ]]; then
    echo "timestamp,requested_by,target_user,incident,action,result" > "$AUDIT_CSV"
    /bin/chmod 644 "$AUDIT_CSV" 2>/dev/null || true
  fi
}
audit_append() { echo "$1,$2,$3,$4,$5,$6" >> "$AUDIT_CSV" 2>/dev/null || true; }

is_admin() { /usr/sbin/dseditgroup -o checkmember -m "$1" admin >/dev/null 2>&1; }
add_to_admin() { /usr/sbin/dseditgroup -o edit -a "$1" admin; }

# Convert JSON -> plist and read keys (top-level or container) without jq
plist_node_exists() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" >/dev/null 2>&1; }
json_to_plist() { local tmp; tmp="$(/usr/bin/mktemp /var/tmp/dialog.XXXXXX.plist)"; /usr/bin/plutil -convert xml1 -o "$tmp" "$1" >/dev/null 2>&1 || { rm -f "$tmp"; echo ""; return 1; }; echo "$tmp"; }
plist_print_key() { /usr/libexec/PlistBuddy -c "Print $2" "$1" 2>/dev/null || echo ""; }
json_get_value() {
  local json="$1" key="$2" plist pb_key v
  plist="$(json_to_plist "$json")" || { echo ""; return 0; }
  case "$key" in *[\ \(\):]* ) pb_key=":\"$key\"" ;; * ) pb_key=":$key" ;; esac
  v="$(plist_print_key "$plist" "$pb_key")"
  if [ -z "$v" ]; then
    local c; for c in textfield textfields inputs input; do
      if plist_node_exists "$plist" "$c"; then
        case "$key" in *[\ \(\):]* ) pb_key=":$c:\"$key\"" ;; * ) pb_key=":$c:$key" ;; esac
        v="$(plist_print_key "$plist" "$pb_key")"; [ -n "$v" ] && break
      fi
    done
  fi
  rm -f "$plist" 2>/dev/null
  printf '%s' "$v"
}

show_error() {
  "$DIALOG" --title "Invalid Input" --icon "warning" \
    --message "$1" --button1text "OK" --width 520 --height 170 >/dev/null 2>&1
}

# -------------------- Prompt + validation loop --------------------
require_root
[[ -x "$DIALOG" ]] || abort_dialog "SwiftDialog not found at $DIALOG. Please install SwiftDialog."

ATTEMPT=1
while :; do
  JSON_TMP="$(/usr/bin/mktemp /var/tmp/dialog.XXXXXX.json)"
  # Build textfields; attempt value= prefill (harmless if ignored by your build)
  USER_FIELD="Username"
  INC_FIELD="Request (REQ-123456)"
  [[ -n "$DEFAULT_USERNAME" ]] && USER_FIELD="Username,value=$DEFAULT_USERNAME"
  [[ -n "$DEFAULT_INCIDENT" ]] && INC_FIELD="Incident (REQ-123456),value=$DEFAULT_INCIDENT"

  "$DIALOG" \
    --title "Permanent Local User Elevation" \
    --message "**RUN ONLY ONCE USER/COMPUTER HAS BEEN APPROVED**\n\n Enter the local macOS username (case-sensitive) to elevate and the approved incident number.\n * Username must be a **local** account\n * Request Number must be **REQ-123456**\n * [Link to Local Elevated Access Request Form](https://your-link-to-request-form.com)" \
    --icon "person" \
    --width 900 \
    --height 400 \
    --button1text "Elevate" \
    --button2text "Cancel" \
    --textfield "$USER_FIELD,required" \
    --textfield "$INC_FIELD,required" \
    --json > "$JSON_TMP"
  DLG_EC=$?

  if [[ $DLG_EC -ne 0 ]]; then
    rm -f "$JSON_TMP" 2>/dev/null
    abort_dialog "Cancelled by operator."
  fi

  RAW="$(tr -d '\n' < "$JSON_TMP" 2>/dev/null)"
  [ -n "$RAW" ] && log "Dialog raw JSON: $RAW"

  USERNAME="$(json_get_value "$JSON_TMP" "Username")"
  INCIDENT="$(json_get_value "$JSON_TMP" "Request (REQ-123456)")"
  rm -f "$JSON_TMP" 2>/dev/null

  # Fallback to defaults if JSON didn’t echo them (older builds)
  [[ -z "$USERNAME" && -n "$DEFAULT_USERNAME" ]] && USERNAME="$DEFAULT_USERNAME"
  [[ -z "$INCIDENT" && -n "$DEFAULT_INCIDENT" ]] && INCIDENT="$DEFAULT_INCIDENT"

  log "Dialog capture -> user='${USERNAME:-}' incident='${INCIDENT:-}'"

  # Validation
  if [[ -z "$USERNAME" ]]; then
    show_error "Please enter a username."
  elif is_protected_user "$USERNAME"; then
    show_error "'$USERNAME' is a protected service account and cannot be elevated via this workflow."
  elif ! user_exists "$USERNAME"; then
    show_error "User '$USERNAME' does not exist on this Mac."
  elif ! user_is_local_real "$USERNAME"; then
    show_error "User '$USERNAME' is not a local (UID ≥ 501) account."
  elif [[ -z "$INCIDENT" ]]; then
    show_error "Please enter an incident number (REQ-123456)."
  elif ! [[ "$INCIDENT" =~ ^REQ-[0-9]{6}$ ]]; then
    show_error "Incident must match REQ-###### (exactly six digits). You entered: '$INCIDENT'."
  else
    break
  fi

  ((ATTEMPT++))
  if (( ATTEMPT > 3 )); then
    abort_dialog "Too many invalid attempts. Aborting."
  fi
done

# -------------------- Elevation + Audit --------------------
ensure_audit_store
REQ_BY="$(/usr/bin/whoami)"
TS="$(date '+%Y-%m-%d %H:%M:%S')"

log "Permanent elevation requested for user='$USERNAME' incident='$INCIDENT' requested_by='$REQ_BY'"

if is_admin "$USERNAME"; then
  log "No action: '$USERNAME' already in admin group (permanent)."
  audit_append "$TS" "$REQ_BY" "$USERNAME" "$INCIDENT" "add_to_admin" "already_admin"
  "$DIALOG" --title "No Action Taken" --message "'$USERNAME' is already an admin.\nIncident: $INCIDENT" --icon "info" --button1text "OK" --width 520 --height 360 >/dev/null 2>&1
  exit 0
fi

if add_to_admin "$USERNAME"; then
  log "SUCCESS: Permanently added '$USERNAME' to admin group (incident $INCIDENT)."
  audit_append "$TS" "$REQ_BY" "$USERNAME" "$INCIDENT" "add_to_admin" "success"
  "$DIALOG" --title "Elevation Complete" \
    --message "✅ User '$USERNAME' was permanently added to the admin group.\n\nIncident: $INCIDENT" \
    --icon "success" --button1text "Done" --width 520 --height 360 >/dev/null 2>&1
  exit 0
else
  log "ERROR: Failed to add '$USERNAME' to admin group (incident $INCIDENT)."
  audit_append "$TS" "$REQ_BY" "$USERNAME" "$INCIDENT" "add_to_admin" "error"
  "$DIALOG" --title "Elevation Failed" \
    --message "Could not add '$USERNAME' to admin group.\nCheck logs for details.\nIncident: $INCIDENT" \
    --icon "error" --button1text "OK" --width 520 --height 360 >/dev/null 2>&1
  exit 2
fi
