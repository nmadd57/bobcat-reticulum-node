# Self-recovery

A Bobcat running as a node is usually somewhere you cannot easily reach, so it is
set up to survive the things that went wrong in testing. Installed by default;
turn it off with `RESILIENCE=no` (or `--no-resilience`).

## Why it exists
A unit that had only Wi-Fi dropped off the network and stayed gone until someone
rebooted it. Afterwards there was nothing to explain why:

- Armbian keeps `/var/log` in RAM and copies it to disk only at clean shutdown, so
  a hard reset lost everything since boot (hours of logs);
- after each of Armbian's log syncs, journald is switched back to RAM and stays
  there (`journalctl --relinquish-var`);
- nothing watched the network, and the board's hardware watchdog was never armed,
  so a hang or a wedged Wi-Fi chip could only be fixed by hand.

## What is installed

| Part | What it does |
|---|---|
| **Persistent journal** | journald writes to the eMMC (`Storage=persistent`), and `bobcat-logflush.timer` runs `journalctl --flush` every 5 minutes to put it back there after any Armbian sync. After a crash you can read what led up to it with `journalctl -b -1`. Loss is limited to the last few minutes. |
| **Log limits** | Journal: 20 MB total, 2 MB per file, one file per day, kept `LOG_KEEP_DAYS` (default 14), and it never takes the last 1 GB of free space. Rotated logs Armbian copies to `/var/log.hdd`: removed after `LOG_KEEP_DAYS`, and capped at `LOG_MAX_MB` (default 100) by `bobcat-logprune.timer` (daily), oldest first. Current logs and the live journal are never deleted by the pruner. |
| **Hardware watchdog** | systemd arms the SoC's watchdog (`RuntimeWatchdogSec=30s`). If the system stops answering, the board resets itself. |
| **Panic reset** | `kernel.panic=10`, `panic_on_oops=1`: a kernel panic or oops reboots instead of hanging. |
| **Network watchdog** | `bobcat-netwatch.timer`, every minute: see below. |

## The network watchdog
It pings the default gateway (or `NETWATCH_TARGET`) and counts consecutive failed
minutes:

| Minute | Action |
|---|---|
| 3 | disconnect and reconnect the Wi-Fi device |
| 6 | restart NetworkManager |
| 9 | reload the Wi-Fi driver (the board's SDIO chip can wedge), then restart NetworkManager |
| `NETWATCH_REBOOT_MINUTES` (default 20) | reboot |

- The counter resets as soon as the network answers.
- **A reboot happens at most once every 3 hours**, so a network that is down for a
  reason a reboot cannot fix (router off, no signal) never becomes a reboot loop.
- It does nothing at all on a machine with no Wi-Fi or Ethernet connection profile.
- It does not touch the LoRa side: Reticulum over the radio keeps working while the
  IP network is down. Set `NETWATCH_REBOOT_MINUTES=0` if you never want a reboot
  (the three recovery steps still run).
- Everything it does is in the journal: `journalctl -t bobcat-netwatch`.

## What it does not need
The network watchdog pings the **default gateway**, not the internet, on purpose: a
Wi-Fi network without internet access (an isolated IoT network, say) is still a working
link for a node, and must not make it reboot. If you set `NETWATCH_TARGET`, choose
something that is reachable on that network, never an internet address unless the
network really provides it.

## Settings
| Key | Option | Default | Meaning |
|---|---|---|---|
| `RESILIENCE` | `--no-resilience` | yes | install all of this (no = remove it) |
| `NETWATCH_TARGET` | `--netwatch-target` | the gateway | host or IP to ping |
| `NETWATCH_REBOOT_MINUTES` | `--netwatch-reboot-minutes` | 20 | `0` never, else 5-1440 |
| `LOG_KEEP_DAYS` | `--log-keep-days` | 14 | 1-365 |
| `LOG_MAX_MB` | `--log-max-mb` | 100 | 20-2000 |

Installed files: `/usr/local/sbin/bobcat-netwatch` and `bobcat-logprune`, four
timer/service pairs `bobcat-{netwatch,logflush,logprune}.*` in `/etc/systemd/system`,
`10-bobcat-*.conf` drop-ins for journald, systemd and sysctl, and the settings in
`/etc/bobcat-lora/netwatch.conf` and `logs.conf`.

## Things to know
- **The hardware watchdog cannot be disarmed once started** (this chip has no
  "magic close"). Turning self-recovery off removes the setting, but the watchdog
  keeps running until the next reboot. While it is armed, systemd must keep
  answering; stopping systemd by hand will reset the board.
- The flush timer adds a small, steady write load to the eMMC (the journal is
  capped at 20 MB). It is far less than the 8+ hours of logs that were lost.
- The network watchdog assumes a node that has a network profile should be online.
  A unit that is meant to run on LoRa alone with a profile that never connects
  would reboot every 3 hours: set `NETWATCH_REBOOT_MINUTES=0`, or `RESILIENCE=no`.

## Looking at what happened
```
journalctl -b -1 -e                    # the end of the previous boot (after a crash or reset)
journalctl -t bobcat-netwatch          # what the network watchdog did, and when
journalctl --list-boots                # how many boots are on record
wdctl                                  # hardware watchdog state
systemctl list-timers 'bobcat-*'       # the three timers
```
