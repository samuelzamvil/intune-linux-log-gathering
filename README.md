# intune-linux-log-gather

A diagnostic log collector for Linux devices enrolled in Microsoft Intune. Captures systemd unit state, per-unit journals, and agent check-in signals before and after a manual sync. Pulls the last 24h by default; configurable with `--last` or `--since`. Requires sudo. Tested on Ubuntu and RHEL against Intune agent 1.2511.11.

## Requirements

- Ubuntu (22.04 / 24.04) or RHEL (8 / 9)
- `zip` installed
- `wget` installed (only required for `--ms-support`)
- Must be run with `sudo` as the affected user

## Usage

```bash
sudo bash intune-linux-log-gather.sh [--last|-l <window> | --since|-s <timestamp>] [--ms-support] [--wait-for-additional-diagnostics]
```

| Flag | Description |
|------|-------------|
| `--last`, `-l` | Pull logs from the last N hours or days. Format: `24h`, `7d`. Default: `24h` |
| `--since`, `-s` | Pull logs from an absolute point forward. Format: `2026-03-15` or `"2026-03-15 10:00:00"` |
| `--ms-support` | Collect additional artifacts for a Microsoft support request (see below) |
| `--wait-for-additional-diagnostics` | Pause before zipping so you can add files (e.g. Edge logs) to the ms-support folder on the Desktop. Only meaningful with `--ms-support` |

### Examples

```bash
# Default: last 24 hours
sudo bash intune-linux-log-gather.sh

# Last 7 days
sudo bash intune-linux-log-gather.sh -l 7d

# Last 12 hours
sudo bash intune-linux-log-gather.sh -l 12h

# Everything since a specific date
sudo bash intune-linux-log-gather.sh -s 2026-03-15

# Everything since a specific time
sudo bash intune-linux-log-gather.sh -s "2026-03-15 10:00:00"

# Collect base logs plus MS support artifacts
sudo bash intune-linux-log-gather.sh --ms-support

# MS support mode with pause to add Edge logs before zipping
sudo bash intune-linux-log-gather.sh --ms-support --wait-for-additional-diagnostics
```

## Workflow

Run the script once before attempting a manual check-in, then again after. The timestamp in each zip filename tells you which is which.

```bash
# Before
sudo bash intune-linux-log-gather.sh

# Open the Intune portal app and click Refresh / Check-in

# After
sudo bash intune-linux-log-gather.sh
```

Output is saved to `~/Desktop/intune-logs-<timestamp>.zip`.

## What's collected

Each zip contains the following files in triage order:

| File | Contents |
|------|----------|
| `00-summary.log` | At-a-glance unit states, last exit codes, and key agent journal signals for the log window |
| `01-unit-show.log` | Full `systemctl show` output for all relevant units |
| `02-service-status.log` | `systemctl status` for each Intune-related unit |
| `03-all-services.log` | All system and user services (`--all` flag) |
| `04-timer-status.log` | User and system timer schedules |
| `05-running-processes.log` | `ps aux` snapshot |
| `06-system-unit-journals.log` | Per-unit journal logs for system units |
| `07-user-unit-journals.log` | Per-unit journal logs for user units |
| `08-intune-user-units.log` | Filtered user unit list for Intune and identity broker units |
| `09-package-versions.log` | Installed versions of Intune-related packages |
| `10-system-info.log` | Hostname, OS release, hostnamectl output, user, timestamp, log window |
| `11-registration-ids.log` | Intune registration IDs (Azure, Intune, User) from `~/.config/intune/registration.toml` |

### Units covered

**System:**
- `intune-daemon.service`
- `intune-daemon.socket`
- `microsoft-identity-device-broker.service`

**User (scoped to the invoking user via `sudo -u`):**
- `intune-agent.service`
- `intune-agent.timer`
- `microsoft-identity-broker.service`

## MS support mode (`--ms-support`)

When working a Microsoft support case, the `--ms-support` flag collects additional artifacts that MS support commonly requests. These are saved to a standalone folder on the Desktop (`~/Desktop/ms-support-request-<timestamp>/`) separate from the base log zip.

### What's collected

| File | Contents |
|------|----------|
| `01-package-versions.log` | Explicit version strings for `intune-portal`, `microsoft-identity-broker`, and `microsoft-identity-device-broker` |
| `02-hostname-os.log` | Hostname and Operating System from `hostnamectl` in the format MS support expects |
| `03-registration-ids.log` | Azure, Intune, and User IDs from `registration.toml` |
| `04-identity-diagnostics.log` | Output from `microsoft-identity-diagnostics` tool, including Incident ID |
| `05-edge-logging-instructions.txt` | Instructions for manually collecting Edge verbose logs (requires GUI session) |
| `ADD_ADDITIONAL_DIAGNOSTICS_HERE` | Placeholder file indicating where to drop manually collected artifacts |
| `README.txt` | Index of files and what to provide to MS support |

### Microsoft Identity Diagnostics

The script will download and install the `microsoft-identity-diagnostics` package if the required version is not already present. It checks the installed version via `dpkg-query` before attempting any download. On Ubuntu, it tries the version-matched package URL first (e.g. `ubuntu/24.04/prod/...`) and falls back to the `ubuntu/20.04/prod/...` URL that MS provides. After install, it runs `/opt/microsoft/microsoft-identity-diagnostics/scripts/collect_logs` and captures the output, including the Incident ID that MS support needs.

### Edge verbose logging

Edge verbose logging requires an interactive GUI session and cannot be run under sudo or SSH. The script prints instructions to the terminal and saves them to `05-edge-logging-instructions.txt`. The command to run from a desktop terminal is:

```bash
/opt/microsoft/msedge/./msedge --enable-logging -v=1 --oneauth-log-level=5 --oneauth-log-pii
```

Edge will open and generate logs. After a few seconds, close the browser and save the terminal output. Look for an Incident ID in the output.

### Waiting for additional diagnostics

Use `--wait-for-additional-diagnostics` with `--ms-support` to pause the script after the ms-support folder is created on the Desktop. This gives you time to collect Edge logs or other manual artifacts and drop them into the folder before the script finishes zipping everything. The Edge logging instructions are printed right before the pause so you have the command ready. Press ENTER when done and the script will sync the additional files into the zip.

If `--wait-for-additional-diagnostics` is used without `--ms-support`, the script prints a warning and ignores the flag.

## Notes

- The script must be run with `sudo` as the affected user, not directly as root. It uses `$SUDO_USER` to scope user-context queries correctly and place the output zip in the right home directory.
- `XDG_RUNTIME_DIR` is set explicitly for all user-unit queries to ensure systemd user session access works correctly under sudo.
- The `microsoft-identity-broker` will log `Device not enrolled as IntuneMAMEnrollment returned an empty or null enrollment id` on every token acquisition for MDM-enrolled devices. This is expected and not an error.
- The `--ms-support` flag creates both a standalone folder on the Desktop (for easy file addition) and includes the ms-support data in the zip. When using `--wait-for-additional-diagnostics`, any files added to the Desktop folder during the pause are synced back into the zip.
