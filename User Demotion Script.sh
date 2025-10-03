#!/bin/bash
# Demote local admin users while preserving management accounts.
# Compatible with macOS Bash 3.2 (no 'mapfile', no array requirements).
# Defaults to excluding: mac_admin, administrator
# Optional: EXCLUDE_USERS="name1,name2 otherName"  (commas or spaces)
# Usage: sudo ./demote-local-admins.sh [--dry-run]

set -o pipefail

DRY_RUN=0
[[ "${1-}" == "--dry-run" ]] && DRY_RUN=1

# Require root
if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (sudo)." >&2
  exit 1
fi

LOG_FILE="/var/log/user-demotions.log"
{ touch "$LOG_FILE" && chmod 644 "$LOG_FILE"; } >/dev/null 2>&1

log() {
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[$ts] $*"
  echo "[$ts] $*" >> "$LOG_FILE" 2>/dev/null || true
}

# Exclusions (space-separated). Allow env override/extension.
EXCLUSIONS="mac_admin administrator"
if [[ -n "${EXCLUDE_USERS-}" ]]; then
  # allow comma- or space-separated extras
  EXCLUSIONS="$EXCLUSIONS ${EXCLUDE_USERS//,/ }"
fi

is_excluded() {
  local user="$1" ex
  for ex in $EXCLUSIONS; do
    [[ "$user" == "$ex" ]] && return 0
  done
  return 1
}

demoted=0
skipped=0

log "Starting demotion. Dry run: $DRY_RUN"
log "Exclusions: $EXCLUSIONS"

# Iterate local accounts with UID >= 501 (normal users)
while IFS= read -r user; do
  if is_excluded "$user"; then
    log "Skip '$user' (excluded)"
    ((skipped++))
    continue
  fi

  # If user is in 'admin' group, remove them
  if dseditgroup -o checkmember -m "$user" admin >/dev/null 2>&1; then
    if [[ $DRY_RUN -eq 1 ]]; then
      log "[DRY-RUN] Would remove '$user' from admin"
      ((demoted++))
    else
      if dseditgroup -o edit -d "$user" admin >/dev/null 2>&1; then
        log "Removed '$user' from admin"
        ((demoted++))
      else
        log "WARN: Failed to remove '$user' from admin"
        ((skipped++))
      fi
    fi
  else
    log "Skip '$user' (not in admin)"
    ((skipped++))
  fi
done < <(dscl . list /Users UniqueID 2>/dev/null | awk '$2>=501 {print $1}')

log "Summary: demoted=$demoted skipped=$skipped"
exit 0