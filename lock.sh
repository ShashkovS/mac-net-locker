#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# ENVIRONMENT SETUP
# ==============================================================================
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin"

# ==============================================================================
# CONFIGURATION
# ==============================================================================
EXAM_DOMAINS=("leaders.tech")
EXAM_IPS=("91.107.234.193" "172.67.184.208")
MAX_LOCK_HOURS=8

# Jamf School hostname (resolved at runtime for current IPs)
JAMF_SCHOOL_HOST="theislandprivatescho.jamfcloud.com"
# Fallback IPs if DNS resolution fails (last known good IPs)
JAMF_SCHOOL_FALLBACK_IPS=("3.79.141.249" "35.157.251.70" "63.182.10.54")

# Hardcoded exam schedule (for Jamf School deployment where args aren't supported)
# Format: "YYYY-MM-DD HH:MM"
EXAM_START="2026-05-15 08:30"
EXAM_END="2026-05-15 13:10"

# Optional timezone to enforce on root/Jamf runs before parsing hardcoded dates.
# Leave empty to use the Mac's current timezone.
# EXAM_TIMEZONE="Europe/Nicosia"
EXAM_TIMEZONE=""

# ==============================================================================
# SYSTEM PATHS
# ==============================================================================
INSTALL_PATH="/usr/local/bin/exam_lock_tool"
STATE_FILE="/var/db/exam_netlock_state"
LOG_FILE="/var/log/exam_lock.log"
DAEMON_LOG_ERR="/var/log/exam_daemon.err"
LOCK_DIR="/var/run/exam_netlock.lock"
LOCK_PID_FILE="$LOCK_DIR/pid"

LABEL_WATCHDOG="com.school.examnetlock.watchdog"
LABEL_FAILSAFE="com.school.examnetlock.failsafe"
PLIST_WATCHDOG="/Library/LaunchDaemons/${LABEL_WATCHDOG}.plist"
PLIST_FAILSAFE="/Library/LaunchDaemons/${LABEL_FAILSAFE}.plist"

# Old labels/files are removed idempotently during cleanup.
OLD_LABEL_ACTIVATE="com.school.examnetlock.activate"
OLD_LABEL_REVERT="com.school.examnetlock.revert"
OLD_LABEL_RESTORE="com.school.examnetlock.restore"
OLD_PLIST_ACTIVATE="/Library/LaunchDaemons/${OLD_LABEL_ACTIVATE}.plist"
OLD_PLIST_REVERT="/Library/LaunchDaemons/${OLD_LABEL_REVERT}.plist"
OLD_PLIST_RESTORE="/Library/LaunchDaemons/${OLD_LABEL_RESTORE}.plist"

PF_CONF_PATH="/etc/exam_pf.conf"
PF_MARKER_LABEL="exam_netlock_block_v4"

# ==============================================================================
# HELPERS
# ==============================================================================

usage() {
  cat <<EOF
Usage:
  $0 lock                  (Uses hardcoded EXAM_START/EXAM_END - for Jamf)
  $0 lock --from "YYYY-MM-DD HH:MM" --until "YYYY-MM-DD HH:MM"
  $0 lock [minutes]        (Legacy: lock now for N minutes)
  $0 unlock
  $0 status [--no-elevate]
  $0 doctor [--connectivity] [--no-elevate]

Current hardcoded schedule:
  Start: $EXAM_START
  End:   $EXAM_END

Description:
  Locks macOS network to exam-allowed IPs only.
  Deploy via Jamf with "Run: Just once" - script handles scheduling internally.
EOF
}

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE" >&2
}

parse_datetime() {
  # Convert "YYYY-MM-DD HH:MM" to Unix timestamp.
  # Append :00 seconds to avoid macOS using current seconds.
  date -j -f "%Y-%m-%d %H:%M:%S" "$1:00" "+%s" 2>/dev/null
}

ts_to_calendar() {
  # Returns: month day hour minute (space-separated, no leading zeros).
  date -r "$1" "+%-m %-d %-H %-M"
}

ts_to_string() {
  date -r "$1" "+%Y-%m-%d %H:%M:%S"
}

pf_status() {
  pfctl -s info 2>/dev/null | awk '/^Status:/{print $2; exit}' || echo "Unknown"
}

is_root() {
  [[ "$(id -u)" -eq 0 ]]
}

is_int() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

join_words() {
  local IFS=' '
  echo "$*"
}

has_flag() {
  local wanted="$1"
  shift
  local arg
  for arg in "$@"; do
    [[ "$arg" == "$wanted" ]] && return 0
  done
  return 1
}

shell_quote() {
  printf "'%s'" "$(printf "%s" "$1" | sed "s/'/'\\\\''/g")"
}

as_root_via_gui() {
  local action="$1"
  shift
  local self_path cmd arg escaped
  self_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

  cmd="$(shell_quote "$self_path") $(shell_quote "__root") $(shell_quote "$action")"
  for arg in "$@"; do
    cmd="$cmd $(shell_quote "$arg")"
  done

  escaped="$(printf "%s" "$cmd" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  echo "🔑 Requesting admin privileges..."
  osascript -e "do shell script \"$escaped\" with administrator privileges"
}

state_get() {
  local key="$1"
  [[ -f "$STATE_FILE" ]] || return 0
  awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$STATE_FILE" 2>/dev/null || true
}

state_set() {
  local key="$1" value="$2" tmp
  [[ -f "$STATE_FILE" ]] || return 0
  tmp="$(mktemp "${STATE_FILE}.XXXXXX")"
  awk -F= -v key="$key" -v value="$value" '
    BEGIN { done = 0 }
    $1 == key { print key "=" value; done = 1; next }
    { print }
    END { if (!done) print key "=" value }
  ' "$STATE_FILE" > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$STATE_FILE"
}

acquire_lock() {
  local timeout="${1:-30}" waited=0 pid=""

  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    if [[ -f "$LOCK_PID_FILE" ]]; then
      pid="$(cat "$LOCK_PID_FILE" 2>/dev/null || true)"
      if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
        rm -rf "$LOCK_DIR"
        continue
      fi
    fi

    if [[ "$waited" -ge "$timeout" ]]; then
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done

  echo "$$" > "$LOCK_PID_FILE"
  return 0
}

release_lock() {
  if [[ -f "$LOCK_PID_FILE" ]] && [[ "$(cat "$LOCK_PID_FILE" 2>/dev/null || true)" == "$$" ]]; then
    rm -rf "$LOCK_DIR"
  fi
}

pf_has_marker() {
  pfctl -sr 2>/dev/null | grep -q "$PF_MARKER_LABEL" && return 0
  pfctl -s labels 2>/dev/null | grep -q "$PF_MARKER_LABEL" && return 0
  return 1
}

verify_pf_active() {
  [[ "$(pf_status)" == "Enabled" ]] || return 1
  pf_has_marker || return 1
  return 0
}

launchd_loaded() {
  local label="$1"
  launchctl print "system/$label" >/dev/null 2>&1
}

bootout_label() {
  local label="$1" plist="${2:-}"
  launchctl bootout "system/$label" >/dev/null 2>&1 || true
  if [[ -n "$plist" ]]; then
    launchctl bootout system "$plist" >/dev/null 2>&1 || true
  fi
}

remove_daemon_files() {
  rm -f "$PLIST_WATCHDOG" "$PLIST_FAILSAFE"
  rm -f "$OLD_PLIST_ACTIVATE" "$OLD_PLIST_REVERT" "$OLD_PLIST_RESTORE"
}

bootout_all_daemons() {
  bootout_label "$LABEL_WATCHDOG" "$PLIST_WATCHDOG"
  bootout_label "$LABEL_FAILSAFE" "$PLIST_FAILSAFE"
  bootout_label "$OLD_LABEL_ACTIVATE" "$OLD_PLIST_ACTIVATE"
  bootout_label "$OLD_LABEL_REVERT" "$OLD_PLIST_REVERT"
  bootout_label "$OLD_LABEL_RESTORE" "$OLD_PLIST_RESTORE"
}

install_self() {
  local current_script
  current_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  if [[ "$current_script" != "$INSTALL_PATH" ]]; then
    mkdir -p "$(dirname "$INSTALL_PATH")"
    cp "$current_script" "$INSTALL_PATH"
    chmod 755 "$INSTALL_PATH"
    log "Installed tool to $INSTALL_PATH"
  fi
}

write_state() {
  local requested_start="$1" requested_end="$2" start_ts="$3" end_ts="$4" reason="$5" pf_before="$6"
  local tmp
  tmp="$(mktemp "${STATE_FILE}.XXXXXX")"
  cat > "$tmp" <<EOF
LOCK_VERSION=2
REQUESTED_START_TS=$requested_start
REQUESTED_END_TS=$requested_end
START_TS=$start_ts
END_TS=$end_ts
SCHEDULE_REASON=$reason
PF_STATUS_BEFORE=$pf_before
ACTIVATED=false
EXAM_DOMAINS=$(join_words "${EXAM_DOMAINS[@]}")
EXAM_IPS=$(join_words "${EXAM_IPS[@]}")
RESOLVED_EXAM_IPS=
CREATED_AT_TS=$(date +%s)
EOF
  chmod 600 "$tmp"
  mv "$tmp" "$STATE_FILE"
}

write_plist_watchdog() {
  local tmp
  tmp="$(mktemp "${PLIST_WATCHDOG}.XXXXXX")"
  cat > "$tmp" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL_WATCHDOG</string>
  <key>ProgramArguments</key>
  <array>
    <string>$INSTALL_PATH</string>
    <string>__root</string>
    <string>watchdog</string>
  </array>
  <key>StartInterval</key>
  <integer>30</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$DAEMON_LOG_ERR</string>
  <key>StandardErrorPath</key>
  <string>$DAEMON_LOG_ERR</string>
</dict>
</plist>
EOF
  chmod 644 "$tmp" || {
    rm -f "$tmp"
    return 1
  }
  plutil -lint "$tmp" >/dev/null || {
    rm -f "$tmp"
    return 1
  }
  mv "$tmp" "$PLIST_WATCHDOG" || {
    rm -f "$tmp"
    return 1
  }
  chown root:wheel "$PLIST_WATCHDOG" 2>/dev/null || true
}

write_plist_failsafe() {
  local end_ts="$1" month day hour minute tmp
  read -r month day hour minute <<< "$(ts_to_calendar "$end_ts")"
  tmp="$(mktemp "${PLIST_FAILSAFE}.XXXXXX")"
  cat > "$tmp" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL_FAILSAFE</string>
  <key>ProgramArguments</key>
  <array>
    <string>$INSTALL_PATH</string>
    <string>__root</string>
    <string>failsafe</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Month</key>
    <integer>$month</integer>
    <key>Day</key>
    <integer>$day</integer>
    <key>Hour</key>
    <integer>$hour</integer>
    <key>Minute</key>
    <integer>$minute</integer>
  </dict>
  <key>StartInterval</key>
  <integer>300</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$DAEMON_LOG_ERR</string>
  <key>StandardErrorPath</key>
  <string>$DAEMON_LOG_ERR</string>
</dict>
</plist>
EOF
  chmod 644 "$tmp" || {
    rm -f "$tmp"
    return 1
  }
  plutil -lint "$tmp" >/dev/null || {
    rm -f "$tmp"
    return 1
  }
  mv "$tmp" "$PLIST_FAILSAFE" || {
    rm -f "$tmp"
    return 1
  }
  chown root:wheel "$PLIST_FAILSAFE" 2>/dev/null || true
}

install_daemons() {
  local end_ts="$1"
  bootout_all_daemons
  remove_daemon_files

  write_plist_watchdog || {
    log "ERROR: Failed to write watchdog plist"
    return 1
  }
  write_plist_failsafe "$end_ts" || {
    log "ERROR: Failed to write failsafe plist"
    return 1
  }

  launchctl bootstrap system "$PLIST_WATCHDOG" || {
    log "ERROR: Failed to bootstrap watchdog LaunchDaemon"
    return 1
  }
  launchctl bootstrap system "$PLIST_FAILSAFE" || {
    log "ERROR: Failed to bootstrap failsafe LaunchDaemon"
    return 1
  }

  launchd_loaded "$LABEL_WATCHDOG" || {
    log "ERROR: Watchdog LaunchDaemon did not load"
    return 1
  }
  launchd_loaded "$LABEL_FAILSAFE" || {
    log "ERROR: Failsafe LaunchDaemon did not load"
    return 1
  }
}

normalize_schedule() {
  local requested_start="$1" requested_end="$2" now max_seconds
  local start_ts end_ts reason

  now="$(date +%s)"
  max_seconds=$((MAX_LOCK_HOURS * 3600))

  if [[ "$requested_end" -le "$requested_start" ]] || [[ "$requested_end" -le "$now" ]]; then
    return 1
  elif [[ "$requested_start" -le "$now" ]]; then
    start_ts="$now"
    end_ts="$requested_end"
    reason="started_immediately"
  else
    start_ts="$requested_start"
    end_ts="$requested_end"
    reason="scheduled"
  fi

  if [[ $((end_ts - start_ts)) -gt "$max_seconds" ]]; then
    end_ts=$((start_ts + max_seconds))
    reason="${reason}_capped"
  fi

  echo "$start_ts $end_ts $reason"
}

validate_requested_schedule() {
  local requested_start="$1" requested_end="$2" now

  now="$(date +%s)"

  if [[ "$requested_end" -le "$requested_start" ]]; then
    echo "❌ Exam end must be after exam start." >&2
    return 1
  fi

  if [[ "$requested_end" -le "$now" ]]; then
    echo "❌ Exam schedule has already ended; refusing to apply a stale lock." >&2
    echo "   Update EXAM_START/EXAM_END, pass --from/--until, or use 'lock MINUTES' for an immediate bounded lock." >&2
    return 1
  fi

  return 0
}

resolve_hosts_ipv4() {
  local host
  for host in "$@"; do
    [[ -n "$host" ]] || continue
    dig +short "$host" 2>/dev/null | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || true
  done
}

build_exam_ip_list() {
  local ips
  ips="$({
    printf "%s\n" "${EXAM_IPS[@]}"
    resolve_hosts_ipv4 "${EXAM_DOMAINS[@]}"
  } | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | sort -u | tr '\n' ' ' || true)"
  echo "$ips"
}

gen_pf_conf() {
  local out_file="$1" exam_ips="$2" jamf_ips=""

  if [[ -n "$JAMF_SCHOOL_HOST" ]]; then
    jamf_ips="$(resolve_hosts_ipv4 "$JAMF_SCHOOL_HOST" | sort -u | tr '\n' ' ')"
  fi

  {
    echo "# exam_netlock generated by $INSTALL_PATH"
    echo "set block-policy return"
    echo "set skip on lo0"
    echo "block return inet6 all label \"exam_netlock_block_v6\""
    echo "block return inet all label \"$PF_MARKER_LABEL\""
    # Allow DHCP (network switching).
    echo "pass quick inet proto udp from any port 68 to any port 67 keep state label \"exam_netlock_dhcp_out\""
    echo "pass quick inet proto udp from any port 67 to any port 68 keep state label \"exam_netlock_dhcp_in\""
    # Allow DNS to any server (operational tradeoff for Wi-Fi switching).
    echo "pass out quick inet proto udp to any port 53 keep state label \"exam_netlock_dns_udp\""
    echo "pass out quick inet proto tcp to any port 53 keep state label \"exam_netlock_dns_tcp\""
    # Allow ICMP to private networks (gateway discovery on any network).
    echo "pass out quick inet proto icmp to 10.0.0.0/8 keep state label \"exam_netlock_private_icmp_10\""
    echo "pass out quick inet proto icmp to 172.16.0.0/12 keep state label \"exam_netlock_private_icmp_172\""
    echo "pass out quick inet proto icmp to 192.168.0.0/16 keep state label \"exam_netlock_private_icmp_192\""
    # Allow exam server access.
    local ip
    for ip in $exam_ips; do
      echo "pass out quick inet proto tcp to ${ip} port 443 keep state label \"exam_netlock_exam_tcp443\""
      echo "pass out quick inet proto tcp to ${ip} port 80 keep state label \"exam_netlock_exam_tcp80\""
      echo "pass out quick inet proto icmp to ${ip} keep state label \"exam_netlock_exam_icmp\""
    done
    # Allow Apple APNs broadly enough to survive APNs load balancing.
    echo "pass out quick inet proto tcp to 17.0.0.0/8 port 443 keep state label \"exam_netlock_apns_443\""
    echo "pass out quick inet proto tcp to 17.0.0.0/8 port 5223 keep state label \"exam_netlock_apns_5223\""
    echo "pass out quick inet proto tcp to 17.0.0.0/8 port 2197 keep state label \"exam_netlock_apns_2197\""
    # Allow Jamf School tenant HTTPS.
    if [[ -n "$jamf_ips" ]]; then
      for ip in $jamf_ips; do
        echo "pass out quick inet proto tcp to ${ip} port 443 keep state label \"exam_netlock_jamf_tcp443\""
      done
      log "Resolved $JAMF_SCHOOL_HOST to: $jamf_ips"
    elif [[ -n "$JAMF_SCHOOL_HOST" ]]; then
      log "WARNING: DNS failed for $JAMF_SCHOOL_HOST, using fallback IPs"
      for ip in "${JAMF_SCHOOL_FALLBACK_IPS[@]}"; do
        echo "pass out quick inet proto tcp to ${ip} port 443 keep state label \"exam_netlock_jamf_tcp443\""
      done
      log "Fallback Jamf IPs: ${JAMF_SCHOOL_FALLBACK_IPS[*]}"
    fi
  } > "$out_file"
}

# ==============================================================================
# ROOT LOGIC
# ==============================================================================

root_unlock_impl() {
  local had_state=false prev_pf current_pf restore_failed=false
  current_pf="$(pf_status)"
  prev_pf="$current_pf"
  if [[ -f "$STATE_FILE" ]]; then
    had_state=true
    prev_pf="$(state_get PF_STATUS_BEFORE)"
  fi

  log "Unlocking started..."

  if ! pfctl -f /etc/pf.conf 2>/dev/null; then
    restore_failed=true
    log "WARNING: Failed to reload /etc/pf.conf during unlock"
  fi
  pfctl -F states 2>/dev/null || true

  if pf_has_marker; then
    pfctl -d 2>/dev/null || true
    log "PF disabled because exam rules remained after restore."
  elif [[ "$restore_failed" == true ]]; then
    pfctl -d 2>/dev/null || true
    log "PF disabled because default rule restore failed."
  elif [[ "$had_state" == true ]] && [[ "$prev_pf" == "Disabled" ]]; then
    pfctl -d 2>/dev/null || true
    log "PF disabled (restored pre-lock state)."
  else
    log "PF left enabled or restored to default rules."
  fi

  rm -f "$STATE_FILE" "$PF_CONF_PATH"
  remove_daemon_files
  bootout_all_daemons

  echo "✅ UNLOCKED. Internet restored."
  log "Unlock completed."
}

root_activate_impl() {
  local tmp exam_ips

  log "Activating network lock..."

  exam_ips="$(build_exam_ip_list)"
  if [[ -z "$exam_ips" ]]; then
    log "ERROR: No exam IPs available after resolving domains and explicit IPs"
    return 1
  fi
  log "Exam allowlist IPs: $exam_ips"

  tmp="$(mktemp "${PF_CONF_PATH}.XXXXXX")"
  gen_pf_conf "$tmp" "$exam_ips" || {
    rm -f "$tmp"
    log "ERROR: Failed to generate PF rules"
    return 1
  }
  chmod 600 "$tmp" || {
    rm -f "$tmp"
    log "ERROR: Failed to secure generated PF rules"
    return 1
  }

  if ! pfctl -n -f "$tmp" >/dev/null; then
    log "ERROR: Generated PF rules failed syntax check"
    rm -f "$tmp"
    return 1
  fi

  mv "$tmp" "$PF_CONF_PATH" || {
    rm -f "$tmp"
    log "ERROR: Failed to install generated PF rules"
    return 1
  }

  if [[ "$(pf_status)" != "Enabled" ]]; then
    if ! pfctl -e >/dev/null; then
      log "ERROR: Failed to enable PF"
      return 1
    fi
  fi

  if ! pfctl -f "$PF_CONF_PATH" >/dev/null; then
    log "ERROR: Failed to load PF rules"
    return 1
  fi
  pfctl -F states >/dev/null 2>&1 || true

  if ! verify_pf_active; then
    log "ERROR: PF did not report the expected active exam rules"
    return 1
  fi

  state_set ACTIVATED true
  state_set RESOLVED_EXAM_IPS "$exam_ips"
  log "Network lock ACTIVATED."
}

root_lock_impl() {
  local requested_start="$1" requested_end="$2" normalized start_ts end_ts reason pf_before now
  local start_str end_str

  if ! validate_requested_schedule "$requested_start" "$requested_end"; then
    log "ERROR: Refusing invalid or stale schedule: start=$(ts_to_string "$requested_start"), end=$(ts_to_string "$requested_end")"
    return 1
  fi

  normalized="$(normalize_schedule "$requested_start" "$requested_end")" || {
    log "ERROR: Failed to normalize requested schedule"
    return 1
  }
  read -r start_ts end_ts reason <<< "$normalized"
  now="$(date +%s)"

  if [[ -n "$EXAM_TIMEZONE" ]]; then
    log "Timezone: $EXAM_TIMEZONE"
  else
    log "Timezone: unchanged (system current)"
  fi
  log "Requested schedule: start=$(ts_to_string "$requested_start"), end=$(ts_to_string "$requested_end")"
  log "Effective schedule: start=$(ts_to_string "$start_ts"), end=$(ts_to_string "$end_ts"), reason=$reason"

  root_unlock_impl >/dev/null 2>&1 || true
  install_self
  pf_before="$(pf_status)"
  write_state "$requested_start" "$requested_end" "$start_ts" "$end_ts" "$reason" "$pf_before"

  if ! install_daemons "$end_ts"; then
    root_unlock_impl >/dev/null 2>&1 || true
    echo "❌ Failed to install LaunchDaemons"
    exit 1
  fi

  start_str="$(ts_to_string "$start_ts")"
  end_str="$(ts_to_string "$end_ts")"

  if [[ "$now" -ge "$start_ts" ]]; then
    if ! root_activate_impl; then
      root_unlock_impl >/dev/null 2>&1 || true
      echo "❌ Failed to activate network lock. Internet restored."
      exit 1
    fi
    echo "✅ LOCKED immediately."
    echo "   Unlock at: $end_str"
  else
    echo "✅ SCHEDULED successfully."
    echo "   Lock at:   $start_str"
    echo "   Unlock at: $end_str"
  fi

  if [[ "$reason" == *_capped ]]; then
    echo "⚠️ Schedule exceeded ${MAX_LOCK_HOURS}h and was capped."
  fi
}

root_watchdog_impl() {
  local start_ts end_ts activated now

  if [[ ! -f "$STATE_FILE" ]]; then
    log "watchdog: no state file; cleaning up daemon leftovers"
    remove_daemon_files
    bootout_all_daemons
    return 0
  fi

  start_ts="$(state_get START_TS)"
  end_ts="$(state_get END_TS)"
  activated="$(state_get ACTIVATED)"
  now="$(date +%s)"

  if ! is_int "$start_ts" || ! is_int "$end_ts"; then
    log "watchdog: invalid state file; unlocking for safety"
    root_unlock_impl
    return 1
  fi

  if [[ "$now" -ge "$end_ts" ]]; then
    log "watchdog: end time reached; unlocking"
    root_unlock_impl
    return 0
  fi

  if [[ "$now" -lt "$start_ts" ]]; then
    log "watchdog: waiting for start time $(ts_to_string "$start_ts")"
    return 0
  fi

  if [[ "$activated" != "true" ]] || ! verify_pf_active; then
    log "watchdog: lock should be active; applying rules"
    if ! root_activate_impl; then
      log "watchdog: activation failed; unlocking for safety"
      root_unlock_impl
      return 1
    fi
  else
    log "watchdog: lock active and verified"
  fi
}

root_failsafe_impl() {
  local end_ts now
  if [[ ! -f "$STATE_FILE" ]]; then
    log "failsafe: no state file; cleaning up daemon leftovers"
    remove_daemon_files
    bootout_all_daemons
    return 0
  fi

  end_ts="$(state_get END_TS)"
  now="$(date +%s)"
  if ! is_int "$end_ts"; then
    log "failsafe: invalid end time; unlocking"
    root_unlock_impl
    return 1
  fi

  if [[ "$now" -ge "$end_ts" ]]; then
    log "failsafe: end time reached; unlocking"
    root_unlock_impl
  else
    log "failsafe: end time not reached"
  fi
}

print_state_summary() {
  if [[ ! -f "$STATE_FILE" ]]; then
    echo "State: not present"
    return 0
  fi

  local start_ts end_ts requested_start requested_end activated reason resolved
  requested_start="$(state_get REQUESTED_START_TS)"
  requested_end="$(state_get REQUESTED_END_TS)"
  start_ts="$(state_get START_TS)"
  end_ts="$(state_get END_TS)"
  activated="$(state_get ACTIVATED)"
  reason="$(state_get SCHEDULE_REASON)"
  resolved="$(state_get RESOLVED_EXAM_IPS)"

  echo "State: present"
  echo "Requested start: $(ts_to_string "$requested_start" 2>/dev/null || echo "$requested_start")"
  echo "Requested end:   $(ts_to_string "$requested_end" 2>/dev/null || echo "$requested_end")"
  echo "Effective start: $(ts_to_string "$start_ts" 2>/dev/null || echo "$start_ts")"
  echo "Effective end:   $(ts_to_string "$end_ts" 2>/dev/null || echo "$end_ts")"
  echo "Reason:          $reason"
  echo "Activated:       $activated"
  echo "Resolved IPs:    ${resolved:-not resolved yet}"
}

root_status_impl() {
  echo "Exam Network Lock Status"
  echo "------------------------"
  print_state_summary
  echo
  echo "PF status: $(pf_status)"
  if pf_has_marker; then
    echo "PF marker: present"
  else
    echo "PF marker: missing"
  fi
  echo
  if launchd_loaded "$LABEL_WATCHDOG"; then
    echo "Watchdog daemon: loaded"
  else
    echo "Watchdog daemon: not loaded"
  fi
  if launchd_loaded "$LABEL_FAILSAFE"; then
    echo "Failsafe daemon: loaded"
  else
    echo "Failsafe daemon: not loaded"
  fi
}

limited_status_impl() {
  echo "Exam Network Lock Status (limited)"
  echo "----------------------------------"
  if [[ -r "$STATE_FILE" ]]; then
    print_state_summary
  elif [[ -e "$STATE_FILE" ]]; then
    echo "State: present (admin privileges required)"
  else
    echo "State: not present"
  fi
  [[ -f "$PLIST_WATCHDOG" ]] && echo "Watchdog plist: present" || echo "Watchdog plist: missing"
  [[ -f "$PLIST_FAILSAFE" ]] && echo "Failsafe plist: present" || echo "Failsafe plist: missing"
  if pfctl -s info >/dev/null 2>&1; then
    echo "PF status: $(pf_status)"
  else
    echo "PF status: requires admin privileges"
  fi
}

doctor_issue() {
  echo "❌ $*"
}

doctor_ok() {
  echo "✅ $*"
}

root_doctor_impl() {
  local connectivity=false now start_ts end_ts issues=0 expected_active=false

  if has_flag "--connectivity" "$@"; then
    connectivity=true
  fi

  echo "Exam Network Lock Doctor"
  echo "------------------------"

  if [[ ! -f "$STATE_FILE" ]]; then
    doctor_ok "No state file"
    if pf_has_marker; then
      doctor_issue "PF exam marker is present without state"
      issues=$((issues + 1))
    else
      doctor_ok "No PF exam marker"
    fi
    if launchd_loaded "$LABEL_WATCHDOG" || launchd_loaded "$LABEL_FAILSAFE"; then
      doctor_issue "LaunchDaemons are loaded without state"
      issues=$((issues + 1))
    else
      doctor_ok "No LaunchDaemon leftovers"
    fi
  else
    start_ts="$(state_get START_TS)"
    end_ts="$(state_get END_TS)"
    now="$(date +%s)"

    if ! is_int "$start_ts" || ! is_int "$end_ts"; then
      doctor_issue "State file has invalid timestamps"
      issues=$((issues + 1))
    else
      echo "Effective start: $(ts_to_string "$start_ts")"
      echo "Effective end:   $(ts_to_string "$end_ts")"
      if [[ "$now" -ge "$end_ts" ]]; then
        doctor_issue "Lock is expired but state still exists"
        issues=$((issues + 1))
      elif [[ "$now" -ge "$start_ts" ]]; then
        expected_active=true
      else
        doctor_ok "Lock is scheduled but not active yet"
      fi
    fi

    if launchd_loaded "$LABEL_WATCHDOG"; then
      doctor_ok "Watchdog daemon loaded"
    else
      doctor_issue "Watchdog daemon is not loaded"
      issues=$((issues + 1))
    fi
    if launchd_loaded "$LABEL_FAILSAFE"; then
      doctor_ok "Failsafe daemon loaded"
    else
      doctor_issue "Failsafe daemon is not loaded"
      issues=$((issues + 1))
    fi

    if [[ "$expected_active" == true ]]; then
      if verify_pf_active; then
        doctor_ok "PF exam rules are active"
      else
        doctor_issue "PF exam rules are not verifiably active"
        issues=$((issues + 1))
      fi
    fi
  fi

  if [[ "$connectivity" == true ]]; then
    run_connectivity_checks "$expected_active" || issues=$((issues + 1))
  fi

  if [[ "$issues" -eq 0 ]]; then
    echo "✅ Doctor passed"
    return 0
  fi
  echo "❌ Doctor found $issues issue(s)"
  return 2
}

run_connectivity_checks() {
  local expected_active="$1" issues=0
  echo
  echo "Connectivity checks"
  echo "-------------------"

  if ! command -v curl >/dev/null 2>&1; then
    doctor_issue "curl is not available"
    return 1
  fi

  if curl -fsS -I --connect-timeout 5 https://leaders.tech >/dev/null 2>&1; then
    doctor_ok "Allowed URL reachable: https://leaders.tech"
  else
    doctor_issue "Allowed URL is not reachable: https://leaders.tech"
    issues=$((issues + 1))
  fi

  if [[ "$expected_active" == true ]]; then
    if curl -fsS -I --connect-timeout 5 https://example.com >/dev/null 2>&1; then
      doctor_issue "Blocked test URL unexpectedly reachable: https://example.com"
      issues=$((issues + 1))
    else
      doctor_ok "Blocked test URL failed as expected: https://example.com"
    fi
  else
    echo "Blocked URL check skipped because no active lock is expected."
  fi

  [[ "$issues" -eq 0 ]]
}

root_lock() {
  acquire_lock 60 || {
    echo "❌ Another exam lock operation is running"
    exit 1
  }
  trap release_lock EXIT
  root_lock_impl "$1" "$2"
}

root_unlock() {
  acquire_lock 60 || {
    echo "❌ Another exam lock operation is running"
    exit 1
  }
  trap release_lock EXIT
  root_unlock_impl
}

root_watchdog() {
  acquire_lock 5 || {
    log "watchdog: another operation is running; skipping this interval"
    exit 0
  }
  trap release_lock EXIT
  root_watchdog_impl
}

root_failsafe() {
  acquire_lock 5 || {
    log "failsafe: another operation is running; skipping this interval"
    exit 0
  }
  trap release_lock EXIT
  root_failsafe_impl
}

# ==============================================================================
# ARGUMENT PARSING
# ==============================================================================

parse_lock_args() {
  local from_dt="" until_dt=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from)
        [[ $# -ge 2 ]] || {
          echo "❌ Missing value for --from" >&2
          return 1
        }
        from_dt="$2"
        shift 2
        ;;
      --until)
        [[ $# -ge 2 ]] || {
          echo "❌ Missing value for --until" >&2
          return 1
        }
        until_dt="$2"
        shift 2
        ;;
      *)
        if [[ "$1" =~ ^[0-9]+$ ]]; then
          local minutes="$1" now
          if [[ "$minutes" -le 0 ]]; then
            echo "❌ Lock duration must be a positive number of minutes" >&2
            return 1
          fi
          now="$(date +%s)"
          echo "$now $((now + minutes * 60))"
          return 0
        fi
        echo "❌ Unknown argument: $1" >&2
        return 1
        ;;
    esac
  done

  if [[ -n "$from_dt" || -n "$until_dt" ]]; then
    [[ -n "$from_dt" && -n "$until_dt" ]] || {
      echo "❌ Both --from and --until are required" >&2
      return 1
    }

    local start_ts end_ts
    start_ts="$(parse_datetime "$from_dt")"
    end_ts="$(parse_datetime "$until_dt")"

    if [[ -z "$start_ts" ]]; then
      echo "❌ Invalid --from datetime: $from_dt" >&2
      return 1
    fi
    if [[ -z "$end_ts" ]]; then
      echo "❌ Invalid --until datetime: $until_dt" >&2
      return 1
    fi

    echo "$start_ts $end_ts"
    return 0
  fi

  local start_ts end_ts
  start_ts="$(parse_datetime "$EXAM_START")"
  end_ts="$(parse_datetime "$EXAM_END")"

  if [[ -z "$start_ts" || -z "$end_ts" ]]; then
    echo "❌ Invalid hardcoded EXAM_START/EXAM_END in script" >&2
    return 1
  fi

  echo "$start_ts $end_ts"
}

# ==============================================================================
# DISPATCHER
# ==============================================================================

if [[ "${1:-}" == "__root" ]]; then
  is_root || exit 1
  case "${2:-}" in
    lock)
      if [[ $# -lt 4 ]] || ! is_int "${3:-}" || ! is_int "${4:-}"; then
        echo "❌ Internal lock requires numeric start/end timestamps" >&2
        exit 1
      fi
      root_lock "$3" "$4"
      ;;
    unlock)    root_unlock ;;
    watchdog)  root_watchdog ;;
    failsafe)  root_failsafe ;;
    status)    root_status_impl ;;
    doctor)    shift 2; root_doctor_impl "$@" ;;
    *)         usage; exit 1 ;;
  esac
  exit 0
fi

action="${1:-lock}"
shift || true

# Set timezone before parsing times when already root. Jamf runs as root.
if is_root && [[ -n "$EXAM_TIMEZONE" ]]; then
  systemsetup -settimezone "$EXAM_TIMEZONE" 2>/dev/null || true
fi

case "$action" in
  lock)
    timestamps="$(parse_lock_args "$@")" || exit 1
    read -r start_ts end_ts <<< "$timestamps"
    validate_requested_schedule "$start_ts" "$end_ts" || exit 1
    if is_root; then
      root_lock "$start_ts" "$end_ts"
    else
      as_root_via_gui "lock" "$start_ts" "$end_ts"
    fi
    ;;
  unlock)
    if is_root; then
      root_unlock
    else
      as_root_via_gui "unlock"
    fi
    ;;
  status)
    if is_root; then
      root_status_impl
    else
      limited_status_impl
      if ! has_flag "--no-elevate" "$@"; then
        echo
        as_root_via_gui "status" || {
          echo "⚠️ Full admin status was cancelled or failed."
          exit 1
        }
      else
        echo "Full status requires admin privileges; rerun without --no-elevate to prompt."
      fi
    fi
    ;;
  doctor)
    if is_root; then
      root_doctor_impl "$@"
    else
      limited_status_impl
      if ! has_flag "--no-elevate" "$@"; then
        echo
        as_root_via_gui "doctor" "$@" || {
          echo "⚠️ Full admin doctor was cancelled or failed."
          exit 1
        }
      else
        echo "Full doctor requires admin privileges; rerun without --no-elevate to prompt."
      fi
    fi
    ;;
  *)
    usage
    exit 1
    ;;
esac
