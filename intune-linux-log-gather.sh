#!/usr/bin/env bash
# intune-linux-log-gather.sh
# Run with sudo as the affected user: sudo bash intune-linux-log-gather.sh
# Run once BEFORE check-in attempt, then again AFTER.
# Output: timestamped zip on the user's Desktop
#
# Usage: sudo bash intune-linux-log-gather.sh [--last|-l <window> | --since|-s <timestamp>]
#   --last,   -l <n>     pull logs from the last Nh or Nd (default: 24h)
#                        e.g. -l 12h, -l 7d
#   --since,  -s <time>  pull logs from an absolute point forward
#                        e.g. -s 2026-03-15, -s "2026-03-15 10:00:00"

# --- require sudo ---
if [[ -z "$SUDO_USER" ]]; then
    echo "Run this script with sudo as the affected user: sudo bash intune-linux-log-gather.sh"
    exit 1
fi

USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
USER_UID=$(id -u "$SUDO_USER")
USER_XDG="XDG_RUNTIME_DIR=/run/user/${USER_UID}"

JOURNAL_MODE="last"
LOG_WINDOW="24h"
LOG_SINCE=""

# --- parse args ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --last|-l)
            JOURNAL_MODE="last"
            LOG_WINDOW="${2:?--last requires a value (e.g. 24h, 7d)}"
            shift 2
            ;;
        --since|-s)
            JOURNAL_MODE="since"
            LOG_SINCE="${2:?--since requires a value (e.g. 2026-03-15)}"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1"
            echo "Usage: sudo bash intune-linux-log-gather.sh [--last|-l <window> | --since|-s <timestamp>]"
            echo "  --last examples:  -l 24h, -l 7d, -l 48h"
            echo "  --since examples: -s 2026-03-15, -s \"2026-03-15 10:00:00\""
            exit 1
            ;;
    esac
done

# --- build journalctl --since value ---
if [[ "$JOURNAL_MODE" == "last" ]]; then
    if [[ "$LOG_WINDOW" =~ ^([0-9]+)d$ ]]; then
        JOURNAL_SINCE="${BASH_REMATCH[1]} days ago"
    elif [[ "$LOG_WINDOW" =~ ^([0-9]+)h$ ]]; then
        JOURNAL_SINCE="${BASH_REMATCH[1]} hours ago"
    else
        echo "Invalid --last value: ${LOG_WINDOW}. Use format like 24h or 7d."
        exit 1
    fi
    LOG_DISPLAY="last ${LOG_WINDOW}"
else
    JOURNAL_SINCE="$LOG_SINCE"
    LOG_DISPLAY="since ${LOG_SINCE}"
fi

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
OUTDIR="/tmp/intune-logs-${TIMESTAMP}"
ZIPNAME="${USER_HOME}/Desktop/intune-logs-${TIMESTAMP}.zip"

mkdir -p "$OUTDIR"

echo "Collecting Intune diagnostic snapshot @ ${TIMESTAMP} (${LOG_DISPLAY})"
echo "Running as: root via sudo, target user: ${SUDO_USER} (uid=${USER_UID})"

# --- helper: get a single property from systemctl show ---
sys_prop()  { systemctl show "$1" --property="$2" 2>/dev/null | cut -d= -f2-; }
user_prop() { sudo -u "$SUDO_USER" $USER_XDG systemctl --user show "$1" --property="$2" 2>/dev/null | cut -d= -f2-; }

# --- collect show data for all relevant units (full output, saved to file) ---
{
    for unit in intune-daemon.service intune-daemon.socket microsoft-identity-device-broker.service; do
        echo "=== ${unit} (system) ==="
        systemctl show "$unit" 2>&1
        echo ""
    done

    for unit in intune-agent.service intune-agent.timer microsoft-identity-broker.service; do
        echo "=== ${unit} (user: ${SUDO_USER}) ==="
        sudo -u "$SUDO_USER" $USER_XDG systemctl --user show "$unit" 2>&1
        echo ""
    done

} > "$OUTDIR/01-unit-show.log" 2>&1

# --- service / socket / timer status ---
{
    echo "=== intune-daemon.service (system) ==="
    systemctl status intune-daemon.service 2>&1

    echo ""
    echo "=== intune-daemon.socket (system) ==="
    systemctl status intune-daemon.socket 2>&1

    echo ""
    echo "=== intune-agent.service (user: ${SUDO_USER}) ==="
    sudo -u "$SUDO_USER" $USER_XDG systemctl --user status intune-agent.service 2>&1

    echo ""
    echo "=== intune-agent.timer (user: ${SUDO_USER}) ==="
    sudo -u "$SUDO_USER" $USER_XDG systemctl --user status intune-agent.timer 2>&1

    echo ""
    echo "=== microsoft-identity-broker.service (user: ${SUDO_USER}) ==="
    sudo -u "$SUDO_USER" $USER_XDG systemctl --user status microsoft-identity-broker.service 2>&1

    echo ""
    echo "=== microsoft-identity-device-broker.service (system) ==="
    systemctl status microsoft-identity-device-broker.service 2>&1

} > "$OUTDIR/02-service-status.log" 2>&1

# --- all services (system and user) ---
{
    echo "=== All system services ==="
    systemctl list-units --type=service --all 2>&1

    echo ""
    echo "=== All user services (user: ${SUDO_USER}) ==="
    sudo -u "$SUDO_USER" $USER_XDG systemctl --user list-units --type=service --all 2>&1

} > "$OUTDIR/03-all-services.log" 2>&1

# --- timer schedule ---
{
    echo "=== All user timers (user: ${SUDO_USER}) ==="
    sudo -u "$SUDO_USER" $USER_XDG systemctl --user list-timers 2>&1

    echo ""
    echo "=== All system timers (intune-relevant) ==="
    systemctl list-timers 2>&1 | grep -i intune

} > "$OUTDIR/04-timer-status.log" 2>&1

# --- running processes ---
ps aux > "$OUTDIR/05-running-processes.log" 2>&1

# --- per-unit journal logs (system units) ---
{
    echo "=== intune-daemon.service ==="
    journalctl --since "${JOURNAL_SINCE}" -u intune-daemon.service 2>&1

    echo ""
    echo "=== intune-daemon.socket ==="
    journalctl --since "${JOURNAL_SINCE}" -u intune-daemon.socket 2>&1

    echo ""
    echo "=== microsoft-identity-device-broker.service ==="
    journalctl --since "${JOURNAL_SINCE}" -u microsoft-identity-device-broker.service 2>&1

} > "$OUTDIR/06-system-unit-journals.log" 2>&1

# --- per-unit journal logs (user units) ---
{
    echo "=== intune-agent.service (user: ${SUDO_USER}) ==="
    sudo -u "$SUDO_USER" $USER_XDG journalctl --user --since "${JOURNAL_SINCE}" -u intune-agent.service 2>&1

    echo ""
    echo "=== intune-agent.timer (user: ${SUDO_USER}) ==="
    sudo -u "$SUDO_USER" $USER_XDG journalctl --user --since "${JOURNAL_SINCE}" -u intune-agent.timer 2>&1

    echo ""
    echo "=== microsoft-identity-broker.service (user: ${SUDO_USER}) ==="
    sudo -u "$SUDO_USER" $USER_XDG journalctl --user --since "${JOURNAL_SINCE}" -u microsoft-identity-broker.service 2>&1

} > "$OUTDIR/07-user-unit-journals.log" 2>&1

# --- full user unit list ---
sudo -u "$SUDO_USER" $USER_XDG systemctl --user list-units 2>&1 \
    | grep -i "intune\|microsoft-identity" \
    > "$OUTDIR/08-intune-user-units.log" 2>&1

# --- detect distro and gather package versions ---
{
    DISTRO_ID=$(grep -oP '(?<=^ID=).+' /etc/os-release | tr -d '"' | tr '[:upper:]' '[:lower:]')

    echo "=== Detected distro: ${DISTRO_ID} ==="
    echo ""

    case "$DISTRO_ID" in
        ubuntu)
            echo "=== Installed Intune-related packages (dpkg) ==="
            dpkg -l 'intune*' 'microsoft-identity*' 'msft*' 'microsoft-edge-stable' 2>&1
            ;;
        rhel|centos|fedora)
            echo "=== Installed Intune-related packages (rpm) ==="
            rpm -qa 'intune*' 'microsoft-identity*' 'msft*' 'microsoft-edge-stable' 2>&1
            ;;
        *)
            echo "Unsupported or unrecognized distro: ${DISTRO_ID}"
            echo "Only Ubuntu and RHEL are supported. Skipping package query."
            ;;
    esac
} > "$OUTDIR/09-package-versions.log" 2>&1

# --- summary ---
{
    printf "%-44s %s\n" "Snapshot timestamp:"  "${TIMESTAMP}"
    printf "%-44s %s\n" "Hostname:"            "$(hostname)"
    printf "%-44s %s\n" "User:"                "${SUDO_USER} (uid=${USER_UID})"
    printf "%-44s %s\n" "OS:"                  "$(grep -oP '(?<=^PRETTY_NAME=).+' /etc/os-release | tr -d '"')"
    printf "%-44s %s\n" "Log window:"          "${LOG_DISPLAY}"
    echo ""

    echo "----------------------------------------------------------------------"
    printf "%-44s %-12s %-10s %-8s %s\n" "Unit" "Active" "Enabled" "ExitCode" "Last Change"
    echo "----------------------------------------------------------------------"

    print_unit_row() {
        local unit="$1"
        local active enabled exit_code timestamp
        active=$(sys_prop "$unit" ActiveState)
        sub=$(sys_prop "$unit" SubState)
        enabled=$(sys_prop "$unit" UnitFileState)
        exit_code=$(sys_prop "$unit" ExecMainCode)
        timestamp=$(sys_prop "$unit" StateChangeTimestamp)
        printf "%-44s %-12s %-10s %-8s %s\n" \
            "${unit}" "${active}/${sub}" "${enabled:-n/a}" "${exit_code:-n/a}" "${timestamp}"
    }

    print_user_unit_row() {
        local unit="$1"
        local active enabled exit_code timestamp
        active=$(user_prop "$unit" ActiveState)
        sub=$(user_prop "$unit" SubState)
        enabled=$(user_prop "$unit" UnitFileState)
        exit_code=$(user_prop "$unit" ExecMainCode)
        timestamp=$(user_prop "$unit" StateChangeTimestamp)
        printf "%-44s %-12s %-10s %-8s %s\n" \
            "${unit}" "${active}/${sub}" "${enabled:-n/a}" "${exit_code:-n/a}" "${timestamp}"
    }

    print_unit_row      intune-daemon.service
    print_unit_row      intune-daemon.socket
    print_unit_row      microsoft-identity-device-broker.service
    print_user_unit_row intune-agent.service
    print_user_unit_row intune-agent.timer
    print_user_unit_row microsoft-identity-broker.service

    echo ""
    echo "----------------------------------------------------------------------"
    echo "Intune agent journal signals (${LOG_DISPLAY})"
    echo "----------------------------------------------------------------------"

    AGENT_JOURNAL=$(sudo -u "$SUDO_USER" $USER_XDG \
        journalctl --user --since "${JOURNAL_SINCE}" -u intune-agent.service 2>/dev/null)

    last_checkin=$(echo "$AGENT_JOURNAL" | grep -i "Successfully checked in" | tail -1)
    last_skip=$(echo "$AGENT_JOURNAL"    | grep -i "Skipping checkin"         | tail -1)
    last_report=$(echo "$AGENT_JOURNAL"  | grep -i "Reporting status to Intune" | tail -1)
    last_policy=$(echo "$AGENT_JOURNAL"  | grep -i "Processing assigned policies" | tail -1)

    printf "%-44s %s\n" "Last successful check-in:"   "${last_checkin:-(none in window)}"
    printf "%-44s %s\n" "Last skipped check-in:"      "${last_skip:-(none in window)}"
    printf "%-44s %s\n" "Last policy report:"         "${last_report:-(none in window)}"
    printf "%-44s %s\n" "Last policy count:"          "${last_policy:-(none in window)}"

} > "$OUTDIR/00-summary.log" 2>&1

# --- basic system info ---
{
    echo "=== Hostname ==="
    hostname

    echo ""
    echo "=== OS release ==="
    cat /etc/os-release

    echo ""
    echo "=== Invoking user ==="
    echo "$SUDO_USER (uid=${USER_UID})"

    echo ""
    echo "=== Snapshot timestamp ==="
    echo "${TIMESTAMP}"

    echo ""
    echo "=== Log window ==="
    echo "${LOG_DISPLAY}"

} > "$OUTDIR/10-system-info.log" 2>&1

# --- zip, fix ownership, and clean up ---
zip -qr "$ZIPNAME" "$OUTDIR" 2>&1
chown "${SUDO_USER}:" "$ZIPNAME"
rm -rf "$OUTDIR"

echo "Done. Zip saved to: $ZIPNAME"
