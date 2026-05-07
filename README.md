# macOS Exam Network Lock

`lock.sh` is a macOS exam-mode network lock for supervised school Macs. It uses
the built-in packet filter (`pf`) and root LaunchDaemons to block general
network access during one scheduled exam window while keeping a small allowlist
available.

The current script is intentionally hardcoded for easy Jamf rollout to a group
of devices. It is not a VPN, browser extension, or per-app filter.

## Requirements

- Target devices: supervised Apple Silicon macOS devices from the school fleet
  (currently intended for M4 Macs).
- Student account model: students are standard users without sudo or local admin
  rights.
- Operator access: Jamf School or a local macOS admin account is required to
  schedule, install, or remove the lock.
- Network model: normal DHCP Wi-Fi networks are supported. Captive portals are
  out of scope.
- macOS components used by the script:
  - `/sbin/pfctl`
  - `/bin/launchctl`
  - `/usr/bin/osascript`
  - `/usr/sbin/systemsetup`
  - `/usr/bin/dig`

This tool is not a complete device-security solution. If a student has admin
credentials, Recovery access, the ability to remove management profiles, or
another privileged path around local controls, this script cannot enforce the
exam policy by itself.

## Current Configuration

The current configuration is defined near the top of `lock.sh`.

| Setting | Current value |
| --- | --- |
| Exact exam domains | `leaders.tech` |
| Exam IP allowlist | `91.107.234.193`, `172.67.184.208` |
| Default legacy duration | `240` minutes |
| Maximum lock duration | `8` hours |
| Jamf School host | `theislandprivatescho.jamfcloud.com` |
| Jamf fallback IPs | `3.79.141.249`, `35.157.251.70`, `63.182.10.54` |
| APNs allowlist | Apple `17.0.0.0/8` on TCP `443`, `5223`, `2197` |
| Exam start | `2026-03-05 08:45` |
| Exam end | `2026-03-05 13:00` |
| Timezone | `Europe/Nicosia` |
| Installed tool path | `/usr/local/bin/exam_lock_tool` |
| State file | `/var/db/exam_netlock_state` |
| Main log | `/var/log/exam_lock.log` |
| LaunchDaemon log | `/var/log/exam_daemon.err` |
| pf rules file | `/etc/exam_pf.conf` |

The hardcoded exam dates above are historical and must be changed before a real
deployment. If the configured end time is already in the past, the script locks
immediately for `DEFAULT_MINUTES`, capped by `MAX_LOCK_HOURS`, so a stale
deployment still has an automatic unlock.

## How It Works

When `lock` is run as root, the script:

1. Saves the previous `pf` enabled/disabled state.
2. Copies itself to `/usr/local/bin/exam_lock_tool`.
3. Writes lock state to `/var/db/exam_netlock_state`.
4. Creates two system LaunchDaemons:
   - `com.school.examnetlock.watchdog`
   - `com.school.examnetlock.failsafe`
5. Activates immediately if the effective start time has arrived, or lets the
   watchdog poll every 30 seconds until the start time.
6. Generates `/etc/exam_pf.conf`, syntax-checks it with `pfctl -n -f`, enables
   `pf`, loads the rules, flushes states, and verifies that the expected rule
   marker is present.
7. The watchdog keeps checking whether the lock should be active or expired.
   The failsafe daemon is a second path to unlock once the effective end time is
   reached.

The watchdog reapplies the active rules after reboot if the exam window is still
active.

## Network Policy

The generated `pf` policy currently:

- Blocks all IPv6 traffic.
- Blocks all IPv4 traffic by default.
- Allows loopback.
- Allows DHCP for network switching.
- Allows outbound DNS to any server on TCP/UDP port 53.
- Allows ICMP to private gateway ranges.
- Resolves exact hostnames in `EXAM_DOMAINS`, merges them with `EXAM_IPS`, and
  allows TCP 80, TCP 443, and ICMP to the resulting IP list.
- Allows Apple APNs on TCP 443, 5223, and 2197 to `17.0.0.0/8`.
- Resolves the Jamf School host at runtime and allows TCP 443 to the resolved
  IPs, or uses the hardcoded Jamf fallback IPs if resolution fails.

Because `pf` is IP-based here, it cannot enforce DNS names, SNI, HTTP `Host`
headers, or browser URLs. If an allowed IP belongs to a shared CDN such as
Cloudflare, other sites on the same IP may also become reachable. Dedicated
exam-service IPs are safer than shared CDN IPs.

Open DNS is an operational tradeoff. It helps Wi-Fi switching and runtime
resolution, but DNS tunneling and other DNS-based bypass techniques are not
addressed by the current script.

## Jamf And Apple MDM Access

The goal during an exam is narrow: preserve APNs push delivery and outbound
HTTPS check-in to the Jamf School tenant so that Jamf can still reach devices
and run an emergency unlock or remediation command.

This README does not claim full Apple service availability during the lock.
Software updates, VPP/App Store content, iCloud, enrollment flows, attestation,
and other Apple services may be blocked unless their hosts and ports are added.

Apple documents required enterprise hosts and ports in
[Use Apple products on enterprise networks](https://support.apple.com/en-euro/101555).
Jamf School documents APNs/Jamf safelisting in
[Network Ports to Safelist for Jamf School](https://learn.jamf.com/en-US/bundle/jamf-school-security-overview/page/Network_Ports_to_Safelist_for_Jamf_School.html).
Jamf recommends allowing outbound Apple `17.0.0.0/8` access on APNs ports for
reliable APNs behavior. The current script follows that APNs range approach.

## Usage

### Jamf or root deployment

For Jamf School deployment, edit the hardcoded values in `lock.sh`, then run the
script once as root:

```sh
./lock.sh lock
```

This uses the hardcoded `EXAM_START` and `EXAM_END` values. The script handles
installation, scheduling, activation, reboot restore, and scheduled unlock.

### Local admin scheduling

Run with an explicit exam window:

```sh
./lock.sh lock --from "YYYY-MM-DD HH:MM" --until "YYYY-MM-DD HH:MM"
```

Example:

```sh
./lock.sh lock --from "2026-05-08 08:45" --until "2026-05-08 13:00"
```

If the command is started from a non-root GUI session, it uses AppleScript to
show a macOS administrator credential prompt. The user does not type `sudo`, but
valid admin credentials are still required.

### Legacy immediate lock

Lock immediately for a number of minutes:

```sh
./lock.sh lock 240
```

### Unlock

From a local admin or student GUI session:

```sh
./lock.sh unlock
```

From Jamf or another root context, use either the deployed script or the
installed tool:

```sh
/usr/local/bin/exam_lock_tool unlock
```

Non-root unlock from a student session requires a macOS GUI session because the
current privilege elevation path is `osascript ... with administrator
privileges`.

### Status and diagnostics

Show local status:

```sh
./lock.sh status
```

From a student account, `status` first prints only non-sensitive checks that can
be read without admin rights, then requests administrator credentials for full
state, `pf`, and LaunchDaemon details. To skip the credential prompt:

```sh
./lock.sh status --no-elevate
```

Run local consistency checks:

```sh
./lock.sh doctor
```

Run local consistency checks plus live connectivity probes:

```sh
./lock.sh doctor --connectivity
```

## Pre-Exam Validation Checklist

For a full step-by-step student Mac test pass, use [TESTING.md](TESTING.md).

Run this checklist on representative devices before each exam batch.

- Confirm the hardcoded `EXAM_START`, `EXAM_END`, `EXAM_TIMEZONE`, Jamf host,
  exam domains, exam IPs, and fallback IPs are correct.
- If the configured end time is in the past, confirm the operator expects the
  default fail-safe duration behavior.
- Run `./lock.sh lock --from ... --until ...` with a short test window.
- Run `./lock.sh doctor` and confirm the watchdog, failsafe, and `pf` marker are
  healthy.
- Confirm `pf` is enabled and `/etc/exam_pf.conf` contains generated
  `exam_netlock` rules.
- Confirm an allowed exam URL works in the browser.
- Confirm an unrelated external site fails.
- Confirm TCP 80/443 and ICMP behavior to the allowed exam IPs is as expected.
- Confirm Jamf can still deliver a command or check in during the lock.
- Reboot during an active lock and confirm the rules are restored.
- Switch between normal DHCP Wi-Fi networks and confirm the expected behavior.
- Run `./lock.sh unlock` and confirm normal internet access returns.

## Diagnostics

Useful admin/operator commands:

```sh
sudo tail -n 200 /var/log/exam_lock.log
sudo tail -n 200 /var/log/exam_daemon.err
sudo cat /var/db/exam_netlock_state
sudo pfctl -s info
sudo pfctl -sr
sudo launchctl print system/com.school.examnetlock.watchdog
sudo launchctl print system/com.school.examnetlock.failsafe
dig +short leaders.tech
dig +short theislandprivatescho.jamfcloud.com
```

Connectivity checks:

```sh
curl -I https://leaders.tech
curl -I https://example.com
ping -c 3 91.107.234.193
```

Expected behavior during a lock is that allowed exam IPs work and unrelated
internet destinations fail.

## Admin-Only Manual Recovery

Use normal unlock first:

```sh
sudo /usr/local/bin/exam_lock_tool unlock
```

If normal unlock fails and an administrator needs to recover a device manually,
restore the default firewall configuration before removing state. If `pf` was
intentionally enabled before the exam for another firewall policy, omit
`sudo pfctl -d` and reload the expected policy after cleanup.

```sh
sudo pfctl -f /etc/pf.conf
sudo pfctl -F states
sudo pfctl -d
sudo launchctl bootout system /Library/LaunchDaemons/com.school.examnetlock.watchdog.plist
sudo launchctl bootout system /Library/LaunchDaemons/com.school.examnetlock.failsafe.plist
sudo launchctl bootout system /Library/LaunchDaemons/com.school.examnetlock.activate.plist
sudo launchctl bootout system /Library/LaunchDaemons/com.school.examnetlock.revert.plist
sudo launchctl bootout system /Library/LaunchDaemons/com.school.examnetlock.restore.plist
sudo rm -f /var/db/exam_netlock_state
sudo rm -f /etc/exam_pf.conf
sudo rm -f /Library/LaunchDaemons/com.school.examnetlock.watchdog.plist
sudo rm -f /Library/LaunchDaemons/com.school.examnetlock.failsafe.plist
sudo rm -f /Library/LaunchDaemons/com.school.examnetlock.activate.plist
sudo rm -f /Library/LaunchDaemons/com.school.examnetlock.revert.plist
sudo rm -f /Library/LaunchDaemons/com.school.examnetlock.restore.plist
```

Only use this section from an admin account, Jamf command, or other trusted root
context. It intentionally removes the scheduled lock state.

## Known Limitations

- Domain allowlisting is implemented by resolving exact hostnames to IPs at
  activation time; this is still IP allowlisting, not true hostname filtering.
- Shared CDN IPs can allow more than the intended domain.
- IPv6 is fully blocked.
- DNS is open to any server on port 53.
- Captive portals are not supported.
- Activation and watchdog unlock can lag by up to 30 seconds because the
  watchdog polls with `StartInterval=30`; the failsafe daemon is a secondary
  unlock path.
- The current script preserves a narrow Jamf/APNs path, not the full Apple MDM
  service matrix.
- The script currently relies on hardcoded Jamf fallback IPs that must be
  refreshed by the script maintainer before each real deployment batch.
- The current hardcoded schedule is in the past and will be clamped to the
  default fail-safe duration unless edited before use.
