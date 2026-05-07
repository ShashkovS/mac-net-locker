# Student Mac Test Plan

This document describes a full manual test pass for `lock.sh` on a real student
MacBook. Run these tests on a non-critical test device first. The test flow is
designed for a student macOS account with no sudo rights, plus an available
local administrator username and password for the macOS credential prompts.

Do not start with `./lock.sh lock` without arguments during testing. The current
hardcoded exam window in `lock.sh` is historical and in the past, so it will be
clamped to the default fail-safe duration (`DEFAULT_MINUTES`, currently 240
minutes). Use short explicit minute-based tests first.

## Test Goals

Confirm that:

- the CLI works predictably from the student account;
- admin elevation works through the macOS credential prompt;
- the lock actually enables verified `pf` rules;
- allowed Leaders resources remain reachable;
- unrelated internet destinations are blocked during an active lock;
- `status` and `doctor` report useful state;
- re-running `lock` while already locked replaces the active window cleanly;
- reboot during an active lock preserves or reapplies the lock;
- auto-unlock restores normal internet access;
- manual unlock works from the student account with admin credentials;
- stale schedules clamp to a bounded fail-safe window instead of creating a
  stuck lock.

## Known Allowed URLs To Verify

Check these URLs during the active-lock phase:

- `https://wiki.leaders.tech/`
- `https://leaders.tech/python-doc/index.html`
- `https://leaders.tech/cgi-bin/serve-control`
- `https://auth.leaders.tech/`

The tool enforces IP allowlists, not true hostname filtering. At the time of
writing:

- `leaders.tech` resolves to Cloudflare IPs including `172.67.184.208` and
  `104.21.64.120`;
- `wiki.leaders.tech` resolves to `91.107.234.193`;
- `auth.leaders.tech` resolves to `91.107.234.193`;
- `EXAM_IPS` already includes `91.107.234.193` and `172.67.184.208`;
- `EXAM_DOMAINS` includes `leaders.tech`, so activation should also add the
  current resolved IPs for `leaders.tech`.

If any of these hostnames later move to a new IP, update `EXAM_DOMAINS` or
`EXAM_IPS` before using this test as an acceptance test.

## Pre-Test Setup

1. Log in as the student user.

2. Open Terminal.

3. Go to the repository checkout:

   ```sh
   cd /path/to/mac-net-locker
   ```

4. Pull the latest version:

   ```sh
   git pull
   ```

5. Confirm the script is executable:

   ```sh
   ls -l lock.sh
   ```

   Expected: the permissions include `x`, for example `-rwxr-xr-x`.

6. Confirm the current branch and commit:

   ```sh
   git status --branch --short
   git log --oneline -1
   ```

   Expected: the branch is clean and up to date with `origin/main`.

7. Confirm you have local administrator credentials available. Do not proceed if
   there is no known admin username/password for this Mac.

8. Confirm normal internet access before locking:

   ```sh
   curl -I --connect-timeout 10 https://leaders.tech
   curl -I --connect-timeout 10 https://example.com
   ```

   Expected: both commands connect before the lock is active.

## Baseline Status From Student Account

1. Run limited status without admin elevation:

   ```sh
   ./lock.sh status --no-elevate
   ```

   Expected before any lock:

   - `State: not present`
   - `Watchdog plist: missing`
   - `Failsafe plist: missing`
   - `PF status: requires admin privileges` or an actual PF status
   - a note that full status requires admin privileges

2. Run limited doctor without admin elevation:

   ```sh
   ./lock.sh doctor --no-elevate
   ```

   Expected: the same limited local information and a note that full doctor
   requires admin privileges.

3. Run full status:

   ```sh
   ./lock.sh status
   ```

   Enter admin credentials when macOS prompts.

   Expected before any lock:

   - `State: not present`
   - `PF marker: missing`
   - `Watchdog daemon: not loaded`
   - `Failsafe daemon: not loaded`

4. Run full doctor:

   ```sh
   ./lock.sh doctor
   ```

   Enter admin credentials if prompted.

   Expected before any lock:

   - `No state file`
   - `No PF exam marker`
   - `No LaunchDaemon leftovers`
   - `Doctor passed`

If full status or doctor reports leftover state, run manual unlock before
continuing:

```sh
./lock.sh unlock
```

Enter admin credentials when prompted, then re-run `./lock.sh doctor`.

## Smoke Test: Immediate Two-Minute Lock

1. Start a short lock from the student account:

   ```sh
   ./lock.sh lock 2
   ```

2. Enter admin credentials when macOS prompts.

3. Expected command output:

   - `LOCKED immediately`
   - an `Unlock at:` timestamp approximately two minutes in the future

4. Run full status:

   ```sh
   ./lock.sh status
   ```

   Expected:

   - `State: present`
   - `Effective end` approximately two minutes after the lock started
   - `Activated: true`
   - `PF status: Enabled`
   - `PF marker: present`
   - `Watchdog daemon: loaded`
   - `Failsafe daemon: loaded`

5. Run full doctor:

   ```sh
   ./lock.sh doctor
   ```

   Expected:

   - `Watchdog daemon loaded`
   - `Failsafe daemon loaded`
   - `PF exam rules are active`
   - `Doctor passed`

## Allowed URL Checks During Active Lock

Run these checks while the two-minute lock is active. The browser checks are the
primary acceptance checks. The `curl` checks are useful diagnostics.

1. Open each allowed URL in a browser:

   - `https://wiki.leaders.tech/`
   - `https://leaders.tech/python-doc/index.html`
   - `https://leaders.tech/cgi-bin/serve-control`
   - `https://auth.leaders.tech/`

2. Expected browser behavior:

   - each URL should load a page, redirect to an allowed Leaders page, or show an
     application-level login/authorization response;
   - an HTTP `401`, `403`, or login screen can still be acceptable for protected
     resources;
   - DNS, TCP, or TLS connection failures are not acceptable.

3. Run command-line checks:

   ```sh
   for url in \
     "https://wiki.leaders.tech/" \
     "https://leaders.tech/python-doc/index.html" \
     "https://leaders.tech/cgi-bin/serve-control" \
     "https://auth.leaders.tech/"
   do
     result="$(curl -sS -o /dev/null --connect-timeout 10 --max-time 20 \
       -w "http=%{http_code} ip=%{remote_ip}" "$url")"
     rc=$?
     printf "%s -> rc=%s %s\n" "$url" "$rc" "$result"
   done
   ```

   Expected:

   - `rc=0` for each URL;
   - an HTTP code is printed for each URL;
   - `http=401`, `http=403`, or a redirect status can be acceptable for protected
     services;
   - `rc=6`, `rc=7`, `rc=28`, or `http=000` indicates a network or TLS
     reachability problem that needs investigation.

4. Inspect resolved IPs recorded by the tool:

   ```sh
   ./lock.sh status
   ```

   Expected: `Resolved IPs` includes the allowed IPs needed for the Leaders
   resources.

## Blocked Internet Checks During Active Lock

1. Try unrelated sites in a browser:

   - `https://example.com/`
   - `https://www.google.com/`
   - `https://www.youtube.com/`

   Expected: these should fail to load during an active lock.

2. Run command-line checks:

   ```sh
   for url in \
     "https://example.com/" \
     "https://www.google.com/" \
     "https://www.youtube.com/"
   do
     result="$(curl -sS -o /dev/null --connect-timeout 10 --max-time 20 \
       -w "http=%{http_code} ip=%{remote_ip}" "$url")"
     rc=$?
     printf "%s -> rc=%s %s\n" "$url" "$rc" "$result"
   done
   ```

   Expected:

   - these checks should fail during an active lock;
   - `rc=7`, `rc=28`, or `http=000` is expected;
   - a successful HTTP response from these unrelated sites means the lock is not
     restrictive enough.

3. Run optional connectivity doctor:

   ```sh
   ./lock.sh doctor --connectivity
   ```

   Expected:

   - local doctor checks pass;
   - `https://leaders.tech` is reachable;
   - `https://example.com` is not reachable while the lock is active.

## Auto-Unlock Test

1. Wait until at least 30 seconds after the printed `Unlock at:` time.

2. Run:

   ```sh
   ./lock.sh status
   ./lock.sh doctor
   ```

3. Expected:

   - `State: not present`
   - `PF marker: missing`
   - `Watchdog daemon: not loaded`
   - `Failsafe daemon: not loaded`
   - `Doctor passed`

4. Confirm normal internet access has returned:

   ```sh
   curl -I --connect-timeout 10 https://example.com
   ```

   Expected: the command connects successfully.

## Re-Run While Already Locked

1. Start a five-minute lock:

   ```sh
   ./lock.sh lock 5
   ```

   Enter admin credentials.

2. Confirm active state:

   ```sh
   ./lock.sh doctor
   ```

   Expected: `Doctor passed`.

3. Replace it with a two-minute lock:

   ```sh
   ./lock.sh lock 2
   ```

   Enter admin credentials again if prompted.

4. Run:

   ```sh
   ./lock.sh status
   ./lock.sh doctor
   ```

5. Expected:

   - state is present;
   - `Effective end` has moved to approximately two minutes from the second
     command;
   - watchdog and failsafe are loaded once;
   - `PF exam rules are active`;
   - `Doctor passed`.

6. Wait for auto-unlock or run:

   ```sh
   ./lock.sh unlock
   ```

## Manual Unlock Test

1. Start a five-minute lock:

   ```sh
   ./lock.sh lock 5
   ```

2. Confirm active state:

   ```sh
   ./lock.sh doctor
   ```

3. Unlock manually from the student account:

   ```sh
   ./lock.sh unlock
   ```

   Enter admin credentials.

4. Verify:

   ```sh
   ./lock.sh doctor
   curl -I --connect-timeout 10 https://example.com
   ```

   Expected:

   - `Doctor passed`;
   - state is gone;
   - normal internet access is restored.

## Reboot During Active Lock

1. Start a five-minute lock:

   ```sh
   ./lock.sh lock 5
   ```

2. Confirm active state:

   ```sh
   ./lock.sh doctor
   ```

3. Reboot immediately while the lock is active.

4. Log back in as the student user.

5. Return to the repository checkout:

   ```sh
   cd /path/to/mac-net-locker
   ```

6. Run:

   ```sh
   ./lock.sh doctor
   ```

7. If the effective end time has not passed yet, expected:

   - watchdog is loaded;
   - failsafe is loaded;
   - `PF exam rules are active`;
   - unrelated internet sites are blocked.

8. Wait until after the end time, then run:

   ```sh
   ./lock.sh doctor
   curl -I --connect-timeout 10 https://example.com
   ```

   Expected:

   - `Doctor passed`;
   - state and daemons are cleaned up;
   - normal internet access returns.

## Wi-Fi Change Test

Run this only on normal DHCP Wi-Fi networks without captive portals.

1. Start a five-minute lock:

   ```sh
   ./lock.sh lock 5
   ```

2. Confirm active state:

   ```sh
   ./lock.sh doctor
   ```

3. Switch to another known Wi-Fi network.

4. Wait 30-60 seconds.

5. Run:

   ```sh
   ./lock.sh doctor
   ```

6. Re-check allowed and blocked URLs:

   - allowed Leaders URLs should still work;
   - unrelated internet destinations should still fail.

7. Unlock:

   ```sh
   ./lock.sh unlock
   ```

## Stale Schedule Clamp Test

This verifies that an operator mistake cannot create an indefinite lock.

1. Run a lock with a past window:

   ```sh
   ./lock.sh lock --from "2026-03-05 08:45" --until "2026-03-05 13:00"
   ```

2. Enter admin credentials.

3. Expected output:

   - lock starts immediately;
   - output warns that the schedule was stale/invalid;
   - unlock time is approximately `DEFAULT_MINUTES` in the future, capped by
     `MAX_LOCK_HOURS`.

4. Run:

   ```sh
   ./lock.sh status
   ```

5. Expected:

   - `Reason: clamped_to_default` or `clamped_to_default_capped`;
   - `Effective end` is bounded and not indefinite.

6. Do not wait for the full default duration during this test. Unlock manually:

   ```sh
   ./lock.sh unlock
   ```

7. Confirm cleanup:

   ```sh
   ./lock.sh doctor
   ```

## Logs To Collect If A Test Fails

If anything behaves unexpectedly, collect:

```sh
./lock.sh status --no-elevate
./lock.sh doctor --no-elevate
```

Then collect full admin diagnostics:

```sh
./lock.sh status
./lock.sh doctor
sudo tail -n 200 /var/log/exam_lock.log
sudo tail -n 200 /var/log/exam_daemon.err
sudo cat /var/db/exam_netlock_state
sudo pfctl -s info
sudo pfctl -sr
sudo launchctl print system/com.school.examnetlock.watchdog
sudo launchctl print system/com.school.examnetlock.failsafe
dig +short leaders.tech
dig +short wiki.leaders.tech
dig +short auth.leaders.tech
```

Record:

- the command that failed;
- exact terminal output;
- whether the Mac was on Wi-Fi or another network;
- whether the failure happened before or after reboot;
- whether auto-unlock eventually happened.

## Emergency Recovery

First try normal unlock from the student account:

```sh
./lock.sh unlock
```

Enter admin credentials.

If that fails, log in as an admin user or use a trusted root/Jamf context:

```sh
sudo /usr/local/bin/exam_lock_tool unlock
```

If normal unlock still does not restore internet, use the manual recovery
commands in `README.md`.
