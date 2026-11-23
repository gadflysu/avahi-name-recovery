# Avahi Name Recovery

When Avahi unexpectedly encounters a transient mDNS name conflict, it can switch to a numbered fallback and keep publishing it after the original name becomes available again. Avahi Name Recovery gives Avahi another chance to reclaim that original name.

A systemd timer checks the published name every 15 minutes. When it detects a numbered fallback for the expected name, it restarts Avahi so the daemon can probe its configured name again. If recovery fails, the next attempt waits at least one hour.

## Requirements

- Linux with systemd, Bash 4 or later, standard system utilities, and Avahi with D-Bus enabled.
- A running system service named `avahi-daemon.service`. The recovery unit queries its system bus and asks systemd to restart the existing service.

## Install

```sh
sudo install -m 0755 avahi-name-recovery /usr/local/sbin/avahi-name-recovery
sudo install -m 0644 systemd/avahi-name-recovery.service /etc/systemd/system/
sudo install -m 0644 systemd/avahi-name-recovery.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now avahi-name-recovery.timer
```

Run a check immediately or inspect the schedule and logs.

```sh
sudo systemctl start avahi-name-recovery.service
systemctl list-timers avahi-name-recovery.timer
journalctl -u avahi-name-recovery.service
```

## Custom hostnames

The default expected hostname is the kernel hostname's first label, combined with Avahi's current domain from D-Bus. For example, `workbench.example.org` on Avahi's `local` domain becomes `workbench.local`. Comparisons are case-insensitive.

When Avahi uses a configured hostname, machine-ID naming, or an alternate configuration file, supply its expected starting label as a service override. This label is only used for comparison. Avahi chooses its hostname during its regular startup.

```sh
sudo systemctl edit avahi-name-recovery.service
```

```ini
[Service]
Environment=AVAHI_EXPECTED_HOSTNAME=workbench
```

Expected labels use ASCII letters, digits, and interior hyphens. The script checks Avahi's numbered fallback convention, including incrementing an existing suffix and truncating a long label. A name changed manually to a matching fallback is indistinguishable from a conflict using the live hostname alone. A restart briefly interrupts mDNS publication, and an ongoing conflict can still force a numbered name.

## Test

Run the Bash syntax checks and mock regression tests on Linux.

```sh
bash -n avahi-name-recovery
bash -n tests/test-recovery.sh
bash tests/test-recovery.sh
```

## Uninstall

Disable the timer and let any running check finish before cleaning up.

```sh
sudo systemctl disable --now avahi-name-recovery.timer
systemctl status avahi-name-recovery.service
sudo systemctl clean --what=runtime avahi-name-recovery.service
sudo unlink /etc/systemd/system/avahi-name-recovery.timer
sudo unlink /etc/systemd/system/avahi-name-recovery.service
sudo unlink /usr/local/sbin/avahi-name-recovery
sudo systemctl daemon-reload
```
