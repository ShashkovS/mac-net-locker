#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# ENVIRONMENT SETUP
# ==============================================================================
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin"

# ==============================================================================
# CONFIGURATION
# ==============================================================================
EXAM_DOMAIN="leaders.tech"
EXAM_IPS=("91.107.234.193" "172.67.184.208")
DEFAULT_MINUTES=240
MAX_LOCK_HOURS=8

# Jamf School hostname (resolved at runtime for current IPs)
JAMF_SCHOOL_HOST="theislandprivatescho.jamfcloud.com"
# Fallback IPs if DNS resolution fails (last known good IPs)
JAMF_SCHOOL_FALLBACK_IPS=("3.79.141.249" "35.157.251.70" "63.182.10.54")

# Apple APNs hostnames (resolved at runtime) - blocks iCloud while allowing MDM
APPLE_APNS_HOSTS=("courier.push.apple.com" "gateway.push.apple.com")
# Fallback APNs IPs if DNS fails (from 17.57.144.0/22 range)
APPLE_APNS_FALLBACK_IPS=("17.57.146.22" "17.57.146.23" "17.57.146.24" "17.57.146.25" "17.57.146.26" "17.57.146.27" "17.57.146.28")

# Hardcoded exam schedule (for Jamf School deployment where args aren't supported)
# Format: "YYYY-MM-DD HH:MM"
EXAM_START="2026-03-05 08:45"
EXAM_END="2026-03-05 13:00"

# Timezone to enforce on all devices (ensures consistent time interpretation)
EXAM_TIMEZONE="Europe/Nicosia"

# ==============================================================================
# SYSTEM PATHS
# ==============================================================================
INSTALL_PATH="/usr/local/bin/exam_lock_tool"
STATE_FILE="/var/db/exam_netlock_state"
LOG_FILE="/var/log/exam_lock.log"
DAEMON_LOG_ERR="/var/log/exam_daemon.err"

PLIST_REVERT="/Library/LaunchDaemons/com.school.examnetlock.revert.plist"
PLIST_RESTORE="/Library/LaunchDaemons/com.school.examnetlock.restore.plist"
PLIST_ACTIVATE="/Library/LaunchDaemons/com.school.examnetlock.activate.plist"
PF_CONF_PATH="/etc/exam_pf.conf"

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

Current hardcoded schedule:
  Start: $EXAM_START
  End:   $EXAM_END

Description:
  Locks macOS network to exam-allowed IPs only.
  Deploy via Jamf with "Run: Just once" - script handles scheduling internally.
EOF
}

parse_datetime() {
  # Convert "YYYY-MM-DD HH:MM" to Unix timestamp
  # Append :00 seconds to avoid macOS using current seconds
  date -j -f "%Y-%m-%d %H:%M:%S" "$1:00" "+%s" 2>/dev/null
}

ts_to_calendar() {
  # Convert Unix timestamp to calendar components for LaunchDaemon
  # Returns: year month day hour minute (space-separated, no leading zeros)
  local ts="$1"
  date -r "$ts" "+%Y %-m %-d %-H %-M"
}

ts_to_string() {
  # Convert Unix timestamp to human-readable string
  date -r "$1" "+%Y-%m-%d %H:%M:%S"
}

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE" >&2
}

pf_status() {
  pfctl -s info 2>/dev/null | awk '/^Status:/{print $2; exit}' || echo "Unknown"
}

as_root_via_gui() {
  local action="$1"
  shift
  local self_path
  self_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

  local cmd_args="__root $action"
  for arg in "$@"; do
    cmd_args="$cmd_args $arg"
  done

  echo "🔑 Requesting admin privileges..."
  osascript -e "do shell script \"'$self_path' $cmd_args\" with administrator privileges"
}

gen_pf_conf() {
  local out_file="$1"

  {
    echo "set block-policy return"
    echo "set skip on lo0"
    echo "block return inet6 all"
    echo "block return inet all"
    # Allow DHCP (network switching)
    echo "pass quick inet proto udp from any port 68 to any port 67"
    echo "pass quick inet proto udp from any port 67 to any port 68"
    # Allow DNS to any server (enables network switching)
    echo "pass out quick inet proto udp to any port 53 keep state"
    echo "pass out quick inet proto tcp to any port 53 keep state"
    # Allow ICMP to private networks (gateway discovery on any network)
    echo "pass out quick inet proto icmp to 10.0.0.0/8 keep state"
    echo "pass out quick inet proto icmp to 172.16.0.0/12 keep state"
    echo "pass out quick inet proto icmp to 192.168.0.0/16 keep state"
    # Allow exam server access
    for ip in "${EXAM_IPS[@]}"; do
      echo "pass out quick inet proto tcp to ${ip} port 443 keep state"
      echo "pass out quick inet proto tcp to ${ip} port 80  keep state"
      echo "pass out quick inet proto icmp to ${ip} keep state"
    done
    # Allow Apple APNs only (resolved at runtime, fallback to static IPs)
    # Ports: 443 (HTTPS), 5223 (APNs persistent), 2197 (APNs HTTP/2)
    # This blocks iCloud while allowing MDM push notifications
    local apns_ips=""
    for host in "${APPLE_APNS_HOSTS[@]}"; do
      local resolved
      resolved=$(dig +short "$host" 2>/dev/null | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || true)
      if [[ -n "$resolved" ]]; then
        apns_ips="$apns_ips $resolved"
      fi
    done
    apns_ips=$(echo "$apns_ips" | tr ' ' '\n' | sort -u | tr '\n' ' ')
    if [[ -n "$apns_ips" ]]; then
      for ip in $apns_ips; do
        echo "pass out quick inet proto tcp to ${ip} port 443 keep state"
        echo "pass out quick inet proto tcp to ${ip} port 5223 keep state"
        echo "pass out quick inet proto tcp to ${ip} port 2197 keep state"
      done
      log "Resolved APNs hosts to: $apns_ips"
    else
      log "WARNING: DNS failed for APNs hosts, using fallback IPs"
      for ip in "${APPLE_APNS_FALLBACK_IPS[@]}"; do
        echo "pass out quick inet proto tcp to ${ip} port 443 keep state"
        echo "pass out quick inet proto tcp to ${ip} port 5223 keep state"
        echo "pass out quick inet proto tcp to ${ip} port 2197 keep state"
      done
      log "Fallback APNs IPs: ${APPLE_APNS_FALLBACK_IPS[*]}"
    fi
    # Allow Jamf School servers (resolved at runtime, fallback to static IPs)
    if [[ -n "$JAMF_SCHOOL_HOST" ]]; then
      local jamf_ips
      jamf_ips=$(dig +short "$JAMF_SCHOOL_HOST" 2>/dev/null | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || true)
      if [[ -n "$jamf_ips" ]]; then
        for ip in $jamf_ips; do
          echo "pass out quick inet proto tcp to ${ip} port 443 keep state"
        done
        log "Resolved $JAMF_SCHOOL_HOST to: $(echo $jamf_ips | tr '\n' ' ')"
      else
        log "WARNING: DNS failed for $JAMF_SCHOOL_HOST, using fallback IPs"
        for ip in "${JAMF_SCHOOL_FALLBACK_IPS[@]}"; do
          echo "pass out quick inet proto tcp to ${ip} port 443 keep state"
        done
        log "Fallback IPs: ${JAMF_SCHOOL_FALLBACK_IPS[*]}"
      fi
    fi
  } > "$out_file"
}

# ==============================================================================
# ROOT LOGIC
# ==============================================================================

root_unlock() {
  log "Unlocking started..."

  # 1. CRITICAL CHANGE: Restore Internet FIRST
  # Before this script kills itself (via bootout), we must ensure network is up.

  # Check previous state for logging
  local prev_pf="Unknown"
  if [[ -f "$STATE_FILE" ]]; then
    prev_pf=$(grep '^PF_STATUS_BEFORE=' "$STATE_FILE" | head -n1 | cut -d'=' -f2 | tr -d '"')
  fi

  # RESET FIREWALL
  pfctl -f /etc/pf.conf 2>/dev/null || true
  pfctl -F states 2>/dev/null || true

  if [[ "$prev_pf" == "Disabled" ]] || [[ -z "$prev_pf" ]]; then
    pfctl -d 2>/dev/null || true
    log "PF disabled (restored state or default)."
  else
    log "PF left enabled (restored state)."
  fi

  # 2. Cleanup Files
  rm -f "$STATE_FILE" "$PF_CONF_PATH"

  echo "✅ UNLOCKED. Internet restored."
  log "Unlock completed. Removing daemons now..."

  # 3. NOW Unload Daemons (This might kill the script if run by launchd)
  if [[ -f "$PLIST_ACTIVATE" ]]; then
    launchctl bootout system "$PLIST_ACTIVATE" 2>/dev/null || true
    rm -f "$PLIST_ACTIVATE"
  fi
  if [[ -f "$PLIST_REVERT" ]]; then
    launchctl bootout system "$PLIST_REVERT" 2>/dev/null || true
    rm -f "$PLIST_REVERT"
  fi
  if [[ -f "$PLIST_RESTORE" ]]; then
    launchctl bootout system "$PLIST_RESTORE" 2>/dev/null || true
    rm -f "$PLIST_RESTORE"
  fi
}

root_lock() {
  local start_ts="$1"
  local end_ts="$2"
  local current_ts
  current_ts=$(date +%s)

  # Validate duration doesn't exceed maximum
  local duration_hours=$(( (end_ts - start_ts) / 3600 ))
  if [[ "$duration_hours" -gt "$MAX_LOCK_HOURS" ]]; then
    log "ERROR: Lock duration (${duration_hours}h) exceeds maximum (${MAX_LOCK_HOURS}h)"
    echo "❌ Lock duration (${duration_hours}h) exceeds maximum allowed (${MAX_LOCK_HOURS}h)"
    exit 1
  fi

  log "Timezone: $EXAM_TIMEZONE"
  log "Lock scheduled: start=$(ts_to_string "$start_ts"), end=$(ts_to_string "$end_ts"), duration=${duration_hours}h"

  if [[ -f "$STATE_FILE" ]]; then root_unlock; fi

  # Install script to persistent location
  local current_script
  current_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  if [[ "$current_script" != "$INSTALL_PATH" ]]; then
    mkdir -p "$(dirname "$INSTALL_PATH")"
    cp "$current_script" "$INSTALL_PATH"
    chmod 755 "$INSTALL_PATH"
    log "Installed tool to $INSTALL_PATH"
  fi

  local pf_before
  pf_before="$(pf_status)"

  # Save state file
  cat > "$STATE_FILE" <<EOF
START_TS=$start_ts
END_TS=$end_ts
PF_STATUS_BEFORE="$pf_before"
ACTIVATED=false
EOF
  chmod 600 "$STATE_FILE"

  # Create restore daemon (handles reboots)
  cat > "$PLIST_RESTORE" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.school.examnetlock.restore</string>
  <key>ProgramArguments</key>
  <array>
    <string>$INSTALL_PATH</string>
    <string>__root</string>
    <string>restore_check</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$DAEMON_LOG_ERR</string>
  <key>StandardErrorPath</key>
  <string>$DAEMON_LOG_ERR</string>
</dict>
</plist>
EOF
  chmod 644 "$PLIST_RESTORE"
  launchctl bootstrap system "$PLIST_RESTORE"

  # Create revert daemon (polls every 30s, unlocks when end time arrives)
  local end_str
  end_str="$(ts_to_string "$end_ts")"

  cat > "$PLIST_REVERT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.school.examnetlock.revert</string>
  <key>ProgramArguments</key>
  <array>
    <string>$INSTALL_PATH</string>
    <string>__root</string>
    <string>check_unlock</string>
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
  chmod 644 "$PLIST_REVERT"
  launchctl bootstrap system "$PLIST_REVERT"

  # Decide: activate now or schedule for later
  if [[ "$current_ts" -ge "$start_ts" ]]; then
    # Start time has passed — activate immediately
    root_activate
    echo "✅ LOCKED immediately (exam in progress)."
    echo "   Unlock at: $end_str"
  else
    # Start time is in future — use polling daemon to check every 30 seconds
    local start_str
    start_str="$(ts_to_string "$start_ts")"

    # Create polling daemon that checks if it's time to activate
    cat > "$PLIST_ACTIVATE" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.school.examnetlock.activate</string>
  <key>ProgramArguments</key>
  <array>
    <string>$INSTALL_PATH</string>
    <string>__root</string>
    <string>check_activate</string>
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
    chmod 644 "$PLIST_ACTIVATE"
    launchctl bootstrap system "$PLIST_ACTIVATE"

    echo "✅ SCHEDULED successfully."
    echo "   Lock at:   $start_str"
    echo "   Unlock at: $end_str"
    log "Lock scheduled: activate at $start_str, unlock at $end_str"
  fi
}

root_check_activate() {
  # Polling function: check if it's time to activate
  if [[ ! -f "$STATE_FILE" ]]; then
    # No state file — shouldn't happen, cleanup
    launchctl bootout system "$PLIST_ACTIVATE" 2>/dev/null || true
    rm -f "$PLIST_ACTIVATE"
    exit 0
  fi

  local start_ts activated current_ts
  start_ts=$(grep '^START_TS=' "$STATE_FILE" | head -n1 | cut -d'=' -f2)
  activated=$(grep '^ACTIVATED=' "$STATE_FILE" | head -n1 | cut -d'=' -f2)
  current_ts=$(date +%s)

  # Already activated — stop polling
  if [[ "$activated" == "true" ]]; then
    log "check_activate: Already activated, stopping poll daemon"
    launchctl bootout system "$PLIST_ACTIVATE" 2>/dev/null || true
    rm -f "$PLIST_ACTIVATE"
    exit 0
  fi

  # Check if it's time
  if [[ -n "$start_ts" ]] && [[ "$current_ts" -ge "$start_ts" ]]; then
    log "check_activate: Start time reached! Activating..."
    root_activate
    # Stop polling daemon after activation
    launchctl bootout system "$PLIST_ACTIVATE" 2>/dev/null || true
    rm -f "$PLIST_ACTIVATE"
  fi
}

root_check_unlock() {
  # Polling function: check if it's time to unlock
  if [[ ! -f "$STATE_FILE" ]]; then
    # No state file — cleanup and exit
    log "check_unlock: No state file, cleaning up"
    root_unlock
    exit 0
  fi

  local end_ts current_ts
  end_ts=$(grep '^END_TS=' "$STATE_FILE" | head -n1 | cut -d'=' -f2)
  current_ts=$(date +%s)

  # Check if it's time to unlock
  if [[ -n "$end_ts" ]] && [[ "$current_ts" -ge "$end_ts" ]]; then
    log "check_unlock: End time reached! Unlocking..."
    root_unlock
    exit 0
  fi
}

root_activate() {
  log "Activating network lock..."

  gen_pf_conf "$PF_CONF_PATH"
  chmod 600 "$PF_CONF_PATH"

  pfctl -E 2>/dev/null || true
  if ! pfctl -f "$PF_CONF_PATH"; then
    log "ERROR: PF rules failed to load!"
    exit 1
  fi
  pfctl -F states 2>/dev/null || true

  if [[ -f "$STATE_FILE" ]]; then
    sed -i '' 's/^ACTIVATED=.*/ACTIVATED=true/' "$STATE_FILE"
  fi
  log "Network lock ACTIVATED."
}


root_restore_check() {
  if [[ ! -f "$STATE_FILE" ]]; then
    rm -f "$PLIST_RESTORE" "$PLIST_REVERT" "$PLIST_ACTIVATE"
    exit 0
  fi

  local start_ts end_ts activated current_ts
  start_ts=$(grep '^START_TS=' "$STATE_FILE" | head -n1 | cut -d'=' -f2)
  end_ts=$(grep '^END_TS=' "$STATE_FILE" | head -n1 | cut -d'=' -f2)
  activated=$(grep '^ACTIVATED=' "$STATE_FILE" | head -n1 | cut -d'=' -f2)
  current_ts=$(date +%s)

  log "Restore Check: now=$current_ts, start=$start_ts, end=$end_ts, activated=$activated"

  # If past end time, unlock
  if [[ -n "$end_ts" ]] && [[ "$current_ts" -ge "$end_ts" ]]; then
    log "End time passed. Unlocking..."
    root_unlock
    exit 0
  fi

  # If not yet activated
  if [[ "$activated" != "true" ]]; then
    if [[ -n "$start_ts" ]] && [[ "$current_ts" -ge "$start_ts" ]]; then
      # Start time has passed during reboot — activate now
      log "Start time passed during reboot. Activating..."
      root_activate
    else
      # Still before start time — ensure activation daemon is scheduled
      log "Still before start time. Waiting for scheduled activation."
    fi
    exit 0
  fi

  # Already activated — re-enable pf rules after reboot
  if [[ -f "$PF_CONF_PATH" ]]; then
    pfctl -E 2>/dev/null || true
    pfctl -f "$PF_CONF_PATH" 2>/dev/null || true
    log "PF rules re-applied after reboot."
  else
    log "PF config missing. Unlocking..."
    root_unlock
  fi
}

# ==============================================================================
# DISPATCHER
# ==============================================================================

# Internal root command (called by GUI elevation or launchd)
if [[ "${1:-}" == "__root" ]]; then
  [[ "$(id -u)" -ne 0 ]] && exit 1
  case "${2:-}" in
    lock)           root_lock "$3" "$4" ;;  # start_ts end_ts
    unlock)         root_unlock ;;
    activate)       root_activate ;;
    check_activate) root_check_activate ;;
    check_unlock)   root_check_unlock ;;
    restore_check)  root_restore_check ;;
  esac
  exit 0
fi

# Parse user-facing arguments
parse_lock_args() {
  local from_dt="" until_dt=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from)  from_dt="$2"; shift 2 ;;
      --until) until_dt="$2"; shift 2 ;;
      *)
        # Legacy mode: single numeric argument = minutes
        if [[ "$1" =~ ^[0-9]+$ ]]; then
          local minutes="$1"
          local now
          now=$(date +%s)
          echo "$now $((now + minutes * 60))"
          return 0
        fi
        echo "❌ Unknown argument: $1" >&2
        return 1
        ;;
    esac
  done

  # Absolute time mode
  if [[ -n "$from_dt" && -n "$until_dt" ]]; then
    local start_ts end_ts
    start_ts=$(parse_datetime "$from_dt")
    end_ts=$(parse_datetime "$until_dt")

    if [[ -z "$start_ts" ]]; then
      echo "❌ Invalid --from datetime: $from_dt" >&2
      return 1
    fi
    if [[ -z "$end_ts" ]]; then
      echo "❌ Invalid --until datetime: $until_dt" >&2
      return 1
    fi
    if [[ "$end_ts" -le "$start_ts" ]]; then
      echo "❌ --until must be after --from" >&2
      return 1
    fi

    echo "$start_ts $end_ts"
    return 0
  fi

  # No arguments — use hardcoded exam schedule
  if [[ -z "$from_dt" && -z "$until_dt" ]]; then
    local start_ts end_ts
    start_ts=$(parse_datetime "$EXAM_START")
    end_ts=$(parse_datetime "$EXAM_END")

    if [[ -z "$start_ts" || -z "$end_ts" ]]; then
      echo "❌ Invalid hardcoded EXAM_START/EXAM_END in script" >&2
      return 1
    fi

    echo "$start_ts $end_ts"
    return 0
  fi

  echo "❌ Both --from and --until are required" >&2
  return 1
}

action="${1:-lock}"
shift || true

# Set timezone before parsing times (requires root, Jamf runs as root)
if [[ "$(id -u)" -eq 0 ]] && [[ -n "$EXAM_TIMEZONE" ]]; then
  systemsetup -settimezone "$EXAM_TIMEZONE" 2>/dev/null || true
fi

case "$action" in
  lock)
    timestamps=$(parse_lock_args "$@") || exit 1
    read -r start_ts end_ts <<< "$timestamps"

    if [[ "$(id -u)" -eq 0 ]]; then
      # Already root (Jamf School context)
      root_lock "$start_ts" "$end_ts"
    else
      # Need GUI elevation
      as_root_via_gui "lock" "$start_ts" "$end_ts"
    fi
    ;;
  unlock)
    if [[ "$(id -u)" -eq 0 ]]; then
      root_unlock
    else
      as_root_via_gui "unlock"
    fi
    ;;
  *)
    usage
    ;;
esac

