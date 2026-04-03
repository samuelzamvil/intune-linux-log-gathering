#!/usr/bin/env bash
# intune-linux-log-gather.sh
# Run with sudo as the affected user: sudo bash intune-linux-log-gather.sh
# Run once BEFORE check-in attempt, then again AFTER.
# Output: timestamped zip on the user's Desktop
#
# Usage: sudo bash intune-linux-log-gather.sh [--last|-l <window> | --since|-s <timestamp>] [--ms-support] [--wait-for-additional-diagnostics]
#   --last,       -l <n>     pull logs from the last Nh or Nd (default: 24h)
#                            e.g. -l 12h, -l 7d
#   --since,      -s <time>  pull logs from an absolute point forward
#                            e.g. -s 2026-03-15, -s "2026-03-15 10:00:00"
#   --ms-support             collect additional artifacts for a Microsoft
#                            support request (identity diagnostics, Edge
#                            logging instructions, formatted version/ID info)
#   --wait-for-additional-diagnostics
#                            pause before zipping so you can add files (e.g.
#                            Edge logs) to the ms-support folder on the Desktop.
#                            Only meaningful with --ms-support.

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
MS_SUPPORT=false
WAIT_FOR_DIAG=false

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
        --ms-support)
            MS_SUPPORT=true
            shift
            ;;
        --wait-for-additional-diagnostics)
            WAIT_FOR_DIAG=true
            shift
            ;;
        *)
            echo "Unknown argument: $1"
            echo "Usage: sudo bash intune-linux-log-gather.sh [--last|-l <window> | --since|-s <timestamp>] [--ms-support] [--wait-for-additional-diagnostics]"
            echo "  --last examples:  -l 24h, -l 7d, -l 48h"
            echo "  --since examples: -s 2026-03-15, -s \"2026-03-15 10:00:00\""
            echo "  --ms-support:                      collect additional data for MS support requests"
            echo "  --wait-for-additional-diagnostics:  pause before zipping to add files to ms-support folder"
            exit 1
            ;;
    esac
done

# --wait-for-additional-diagnostics only makes sense with --ms-support
if [[ "$WAIT_FOR_DIAG" == true ]] && [[ "$MS_SUPPORT" == false ]]; then
    echo "WARNING: --wait-for-additional-diagnostics has no effect without --ms-support. Ignoring."
    WAIT_FOR_DIAG=false
fi

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
if [[ "$MS_SUPPORT" == true ]]; then
    echo "MS Support mode enabled -- collecting additional artifacts"
fi

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

# --- Intune registration IDs (Azure, Intune, User) ---
{
    REGISTRATION_TOML="${USER_HOME}/.config/intune/registration.toml"
    echo "=== Intune Registration IDs ==="
    echo "Source: ${REGISTRATION_TOML}"
    echo ""
    if [[ -f "$REGISTRATION_TOML" ]]; then
        cat "$REGISTRATION_TOML"
    else
        echo "File not found: ${REGISTRATION_TOML}"
        echo "Device may not be enrolled or registration file is in a non-standard location."
    fi
} > "$OUTDIR/11-registration-ids.log" 2>&1

# --- basic system info ---
{
    echo "=== Hostname ==="
    hostname

    echo ""
    echo "=== hostnamectl ==="
    hostnamectl 2>&1

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

} > "$OUTDIR/00-summary.log" 2>&1

# =============================================================================
# MS SUPPORT REQUEST COLLECTION (--ms-support)
# =============================================================================
if [[ "$MS_SUPPORT" == true ]]; then
    MSDIR="$OUTDIR/ms-support-request"
    mkdir -p "$MSDIR"

    echo ""
    echo "--- MS Support: Collecting additional artifacts ---"

    # --- MS Request 1: Intune app and Identity broker versions ---
    {
        DISTRO_ID=$(grep -oP '(?<=^ID=).+' /etc/os-release | tr -d '"' | tr '[:upper:]' '[:lower:]')

        echo "=== Intune App and Identity Broker Versions ==="
        echo ""

        case "$DISTRO_ID" in
            ubuntu)
                echo "-- intune-portal --"
                dpkg-query -W -f='Package: ${Package}\nVersion: ${Version}\nStatus: ${Status}\n' intune-portal 2>&1 || echo "intune-portal not installed"
                echo ""
                echo "-- microsoft-identity-broker --"
                dpkg-query -W -f='Package: ${Package}\nVersion: ${Version}\nStatus: ${Status}\n' microsoft-identity-broker 2>&1 || echo "microsoft-identity-broker not installed"
                echo ""
                echo "-- microsoft-identity-device-broker --"
                dpkg-query -W -f='Package: ${Package}\nVersion: ${Version}\nStatus: ${Status}\n' microsoft-identity-device-broker 2>&1 || echo "microsoft-identity-device-broker not installed"
                ;;
            rhel|centos|fedora)
                echo "-- intune-portal --"
                rpm -qi intune-portal 2>&1 || echo "intune-portal not installed"
                echo ""
                echo "-- microsoft-identity-broker --"
                rpm -qi microsoft-identity-broker 2>&1 || echo "microsoft-identity-broker not installed"
                echo ""
                echo "-- microsoft-identity-device-broker --"
                rpm -qi microsoft-identity-device-broker 2>&1 || echo "microsoft-identity-device-broker not installed"
                ;;
            *)
                echo "Unsupported distro: ${DISTRO_ID}. Cannot query package versions."
                ;;
        esac
    } > "$MSDIR/01-package-versions.log" 2>&1

    # --- MS Request 4: Hostname and OS (hostnamectl format) ---
    {
        echo "=== Hostname and Operating System ==="
        echo ""
        hostnamectl 2>&1 | grep -i "hostname\|operating"
    } > "$MSDIR/02-hostname-os.log" 2>&1

    # --- MS Request 5: Registration IDs (Azure, Intune, User) ---
    {
        REGISTRATION_TOML="${USER_HOME}/.config/intune/registration.toml"
        echo "=== Intune Registration IDs ==="
        echo "Source: ${REGISTRATION_TOML}"
        echo ""
        if [[ -f "$REGISTRATION_TOML" ]]; then
            cat "$REGISTRATION_TOML"
        else
            echo "File not found: ${REGISTRATION_TOML}"
            echo "Device may not be enrolled or registration file is in a non-standard location."
        fi
    } > "$MSDIR/03-registration-ids.log" 2>&1

    # --- MS Request 3: Microsoft Identity Diagnostics ---
    echo ""
    echo "--- MS Support: Installing and running microsoft-identity-diagnostics ---"

    DIAG_LOG="$MSDIR/04-identity-diagnostics.log"
    DIAG_PKG_NAME="microsoft-identity-diagnostics"
    DIAG_PKG_VERSION="1.1.0"
    DIAG_DEB="/tmp/${DIAG_PKG_NAME}_${DIAG_PKG_VERSION}_amd64.deb"
    DIAG_SCRIPT="/opt/microsoft/microsoft-identity-diagnostics/scripts/collect_logs"

    # Try to match the Ubuntu version for the package URL. MS provided 20.04
    # as the source, but it may work across versions. Try the detected version
    # first, then fall back to 20.04.
    UBUNTU_VER=$(grep -oP '(?<=^VERSION_ID=")[0-9.]+' /etc/os-release 2>/dev/null)
    DIAG_PKG_URL_VERSIONED="https://packages.microsoft.com/ubuntu/${UBUNTU_VER}/prod/pool/main/m/${DIAG_PKG_NAME}/${DIAG_PKG_NAME}_${DIAG_PKG_VERSION}_amd64.deb"
    DIAG_PKG_URL_FALLBACK="https://packages.microsoft.com/ubuntu/20.04/prod/pool/main/m/${DIAG_PKG_NAME}/${DIAG_PKG_NAME}_${DIAG_PKG_VERSION}_amd64.deb"

    {
        echo "=== Microsoft Identity Diagnostics ==="
        echo "Detected Ubuntu version: ${UBUNTU_VER:-unknown}"
        echo "Required package: ${DIAG_PKG_NAME} ${DIAG_PKG_VERSION}"
        echo ""

        # Check if the required version is already installed
        INSTALLED_VER=$(dpkg-query -W -f='${Version}' "$DIAG_PKG_NAME" 2>/dev/null)
        NEED_INSTALL=true

        if [[ -n "$INSTALLED_VER" ]]; then
            echo "Found installed: ${DIAG_PKG_NAME} ${INSTALLED_VER}"
            if [[ "$INSTALLED_VER" == "$DIAG_PKG_VERSION" ]]; then
                echo "Required version already installed. Skipping download."
                NEED_INSTALL=false
            else
                echo "Installed version (${INSTALLED_VER}) does not match required (${DIAG_PKG_VERSION})."
                echo "Proceeding with download and install."
            fi
        else
            echo "${DIAG_PKG_NAME} is not installed."
        fi
        echo ""

        if [[ "$NEED_INSTALL" == true ]]; then
            # Download -- try version-matched URL first, fall back to 20.04
            DOWNLOAD_OK=false
            if [[ -n "$UBUNTU_VER" ]] && [[ "$UBUNTU_VER" != "20.04" ]]; then
                echo "Attempting download for Ubuntu ${UBUNTU_VER}..."
                if wget -q -O "$DIAG_DEB" "$DIAG_PKG_URL_VERSIONED" 2>&1; then
                    echo "Download complete (Ubuntu ${UBUNTU_VER} package): ${DIAG_DEB}"
                    DOWNLOAD_OK=true
                else
                    echo "No package found for Ubuntu ${UBUNTU_VER}, falling back to 20.04..."
                    rm -f "$DIAG_DEB" 2>/dev/null
                fi
            fi

            if [[ "$DOWNLOAD_OK" == false ]]; then
                echo "Downloading from Ubuntu 20.04 package pool..."
                if wget -q -O "$DIAG_DEB" "$DIAG_PKG_URL_FALLBACK" 2>&1; then
                    echo "Download complete (20.04 fallback): ${DIAG_DEB}"
                    if [[ -n "$UBUNTU_VER" ]] && [[ "$UBUNTU_VER" != "20.04" ]]; then
                        echo "WARNING: Using 20.04 package on Ubuntu ${UBUNTU_VER}. If install fails,"
                        echo "         check with MS support for a version-specific package."
                    fi
                    DOWNLOAD_OK=true
                else
                    echo "ERROR: Failed to download diagnostics package."
                    echo "  Tried: ${DIAG_PKG_URL_VERSIONED}"
                    echo "  Tried: ${DIAG_PKG_URL_FALLBACK}"
                    echo "Download manually and install with: sudo apt install ./<filename>.deb"
                fi
            fi

            # Install
            if [[ -f "$DIAG_DEB" ]]; then
                echo ""
                echo "Installing diagnostics package..."
                DEBIAN_FRONTEND=noninteractive apt-get install -y "$DIAG_DEB" 2>&1
                echo ""
            fi
        fi

        # Run collection
        if [[ -x "$DIAG_SCRIPT" ]]; then
            echo "Running diagnostics log collection..."
            echo ""
            "$DIAG_SCRIPT" 2>&1
        elif [[ -f "$DIAG_SCRIPT" ]]; then
            echo "Running diagnostics log collection..."
            echo ""
            bash "$DIAG_SCRIPT" 2>&1
        else
            echo "ERROR: Diagnostics script not found at ${DIAG_SCRIPT}"
            echo "The package may not have installed correctly."
        fi

        echo ""
        echo "NOTE: Look for an 'Incident ID' in the output above."
        echo "Provide this Incident ID to Microsoft support."

    } > "$DIAG_LOG" 2>&1

    # Print the diagnostics output to terminal too so the user can see the Incident ID
    echo ""
    echo "--- Identity Diagnostics Output ---"
    cat "$DIAG_LOG"
    echo "-----------------------------------"

    # Cleanup downloaded .deb
    rm -f "$DIAG_DEB" 2>/dev/null

    # --- MS Request 2: Edge verbose logging instructions ---
    # This requires an interactive GUI session and cannot run under sudo/SSH.
    # Print instructions for the user to run manually.
    EDGE_INSTRUCTIONS="$MSDIR/05-edge-logging-instructions.txt"
    cat > "$EDGE_INSTRUCTIONS" <<'EDGE_EOF'
=== Microsoft Edge Verbose Logging ===

Microsoft support has requested Edge browser logs with verbose authentication
logging enabled. This MUST be run from a GUI session as the logged-in user
(it cannot be run via SSH or from this script).

Steps:

  1. Open a terminal on the device (not SSH).

  2. Run the following command:

     /opt/microsoft/msedge/./msedge --enable-logging -v=1 --oneauth-log-level=5 --oneauth-log-pii

  3. Edge will open. Wait for log generation to complete (a few seconds).
     When output stops, close the browser.

  4. Copy the terminal output (the verbose log) and save it to a file.

  5. Look for an 'Incident ID' in the output and note it for MS support.

  6. Place the saved log file in the ms-support-request folder on the Desktop.

EDGE_EOF

    # --- MS support README ---
    cat > "$MSDIR/README.txt" <<'README_EOF'
=== MS Support Request Artifacts ===

This folder contains data collected specifically for a Microsoft support case.

Files:
  01-package-versions.log          Intune app and Identity broker version info
  02-hostname-os.log               Hostname and Operating System
  03-registration-ids.log          Azure, Intune, and User IDs from registration.toml
  04-identity-diagnostics.log      Output from microsoft-identity-diagnostics tool
                                   (contains Incident ID for MS support)
  05-edge-logging-instructions.txt Instructions for collecting Edge verbose logs
                                   (must be run manually from a GUI session)

Add any additional manually collected files (Edge logs, etc.) to this folder
before sending to Microsoft support.

When filing with MS support, provide:
  - The Incident ID from 04-identity-diagnostics.log
  - The Incident ID from the Edge verbose logging (collected manually)
  - The contents of 01, 02, and 03 as requested
README_EOF

    # --- Placeholder for additional manual diagnostics ---
    touch "$MSDIR/ADD_ADDITIONAL_DIAGNOSTICS_HERE"

    # --- Copy ms-support folder to Desktop as a standalone folder ---
    MS_DESKTOP_DIR="${USER_HOME}/Desktop/ms-support-request-${TIMESTAMP}"
    cp -r "$MSDIR" "$MS_DESKTOP_DIR"
    chown -R "${SUDO_USER}:" "$MS_DESKTOP_DIR"

    echo "MS Support folder saved to: ${MS_DESKTOP_DIR}"

    # --- Wait for user to add additional files before zipping ---
    if [[ "$WAIT_FOR_DIAG" == true ]]; then
        echo ""
        echo "========================================================================="
        echo " MANUAL STEP REQUIRED: Microsoft Edge Verbose Logging"
        echo "========================================================================="
        echo ""
        echo " MS support needs Edge logs collected from a GUI session."
        echo " This cannot be run via sudo or SSH."
        echo ""
        echo " On the device, from a terminal in the desktop session, run:"
        echo ""
        echo "   /opt/microsoft/msedge/./msedge --enable-logging -v=1 --oneauth-log-level=5 --oneauth-log-pii"
        echo ""
        echo " Edge will open and generate logs. After a few seconds, close the"
        echo " browser and save the terminal output. Look for an 'Incident ID'."
        echo ""
        echo " Full instructions saved to: ms-support-request/05-edge-logging-instructions.txt"
        echo ""
        echo "========================================================================="
        echo " WAITING: Add any additional diagnostics to the ms-support folder"
        echo "========================================================================="
        echo ""
        echo " Folder: ${MS_DESKTOP_DIR}"
        echo ""
        echo " Add Edge verbose logs or any other manually collected files now."
        echo " When you are done, press ENTER to continue and zip everything up."
        echo ""
        read -r -p " Press ENTER to continue... "
        echo ""

        # Re-sync: copy any new files the user added on Desktop back into
        # the temp OUTDIR copy so they get included in the zip
        cp -r "$MS_DESKTOP_DIR"/* "$MSDIR/" 2>/dev/null
        echo "Synced additional files from Desktop folder into zip."
    else
        echo ""
        echo "========================================================================="
        echo " MANUAL STEP REQUIRED: Microsoft Edge Verbose Logging"
        echo "========================================================================="
        echo ""
        echo " MS support needs Edge logs collected from a GUI session."
        echo " This cannot be run via sudo or SSH."
        echo ""
        echo " On the device, from a terminal in the desktop session, run:"
        echo ""
        echo "   /opt/microsoft/msedge/./msedge --enable-logging -v=1 --oneauth-log-level=5 --oneauth-log-pii"
        echo ""
        echo " Edge will open and generate logs. After a few seconds, close the"
        echo " browser and save the terminal output. Look for an 'Incident ID'."
        echo ""
        echo " Full instructions saved to: ms-support-request/05-edge-logging-instructions.txt"
        echo "========================================================================="
        echo ""
    fi
fi

# --- zip (base logs only, ms-support goes to Desktop separately), fix ownership, clean up ---
zip -qr "$ZIPNAME" "$OUTDIR" 2>&1
chown "${SUDO_USER}:" "$ZIPNAME"
rm -rf "$OUTDIR"

echo ""
echo "Done. Zip saved to: $ZIPNAME"
if [[ "$MS_SUPPORT" == true ]]; then
    echo "MS Support folder saved to: ${MS_DESKTOP_DIR}"
    echo "  -> Add Edge verbose logs and any other manual artifacts to that folder."
fi
