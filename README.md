# intune-log-gather

A diagnostic log collector for Linux devices enrolled in Microsoft Intune. Captures systemd unit state, per-unit journals, and agent check-in signals before and after a manual sync. Pulls the last 24h by default; configurable with `--last` or `--since`. Requires sudo. Tested on Ubuntu and RHEL against Intune agent 1.2511.11.

## Requirements

- Ubuntu (22.04 / 24.04) or RHEL (8 / 9)
- `zip` installed
- Must be run with `sudo` as the affected user

## Usage

```bash
sudo bash intune-log-gather.sh [--last|-l <window> | --since|-s <timestamp>]
```

| Flag | Description |
|------|-------------|
| `--last`, `-l` | Pull logs from the last N hours or days. Format: `24h`, `7d`. Default: `24h` |
| `--since`, `-s` | Pull logs from an absolute point forward. Format: `2026-03-15` or `"2026-03-15 10:00:00"` |

### Examples

```bash
# Default: last 24 hours
sudo bash intune-log-gather.sh

# Last 7 days
sudo bash intune-log-gather.sh -l 7d

# Last 12 hours
sudo bash intune-log-gather.sh -l 12h

# Everything since a specific date
sudo bash intune-log-gather.sh -s 2026-03-15

# Everything since a specific time
sudo bash intune-log-gather.sh -s "2026-03-15 10:00:00"
```

## Workflow

Run the script once before attempting a manual check-in, then again after. The timestamp in each zip filename tells you which is which.

```bash
# Before
sudo bash intune-log-gather.sh

# Open the Intune portal app and click Refresh / Check-in

# After
sudo bash intune-log-gather.sh
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
| `10-system-info.log` | Hostname, OS release, user, timestamp, log window |

### Units covered

**System:**
- `intune-daemon.service`
- `intune-daemon.socket`
- `microsoft-identity-device-broker.service`

**User (scoped to the invoking user via `sudo -u`):**
- `intune-agent.service`
- `intune-agent.timer`
- `microsoft-identity-broker.service`

## Notes

- The script must be run with `sudo` as the affected user, not directly as root. It uses `$SUDO_USER` to scope user-context queries correctly and place the output zip in the right home directory.
- `XDG_RUNTIME_DIR` is set explicitly for all user-unit queries to ensure systemd user session access works correctly under sudo.
- The `microsoft-identity-broker` will log `Device not enrolled as IntuneMAMEnrollment returned an empty or null enrollment id` on every token acquisition for MDM-enrolled devices. This is expected and not an error.
