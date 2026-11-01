# Capacity guard and the status override fix

Base: VR-25/acc `dev` at v2025.5.18-dev (908a5a4).

## Why

On a phone that stays plugged in, an idle ("hold") switch such as `constant_charge_current` = 0 keeps the charger
from charging the battery, but the level can still creep up. Two things made ACC mishandle this:

1. `not_charging()` shadowed the `chargingSwitch` array with a string of the same name. `status()` then read
   element `[0]` as the whole spec and `[2]` as empty, so `batt_status_override=Idle` never applied (checked on
   Android's mksh R59). ACC fell back to the kernel `status`, which stays `Charging` at zero current, polled for
   `_STI` seconds, decided the switch had failed and switched charging back on. Fixed with a separate local, `swSpec`.
2. While holding idle above the pause level, nothing brings the level back down. `allow_idle_above_pcap=false`
   only acts while ACC believes it is charging, and is tried twice per daemon run.

## Capacity guard

`capacity_guard=auto|off|HI-LO` (default `auto`: HI = pause_capacity + 2, LO = pause_capacity - 1; LO < HI,
and LO above resume_capacity).

HOLD: the idle switch is on and `status` reads Idle. When capacity reaches HI in HOLD, the guard cuts the charger
input with a switch that discharges the battery (DRAIN) until capacity falls to LO, then returns to HOLD.

- The discharging switch is found by measurement, not configured. Candidates come from `ch-switches`: single
  switches whose file name looks like an input or charging switch, never the hold switch or a current/voltage
  control file. Each is flipped and kept only if `not_charging Discharging` confirms the battery discharges;
  otherwise it is flipped back. The last working one is cached in `acc-data/drain-switch` and tried first.
- A drain ends at LO, at the resume level, after `drainMaxSec` (6 h), when battery temperature reaches max_temp,
  or when `/dev/.vr25/acc/.stopdrain` exists. It also ends when the daemon exits or starts.
- If the daemon is killed without running its exit handler, a detached timer undoes the drain after
  `drainMaxSec` + 120 s. The marker `/dev/.vr25/acc/.draining` holds the switch and a token (the drain's start
  time); the timer acts only if the marker still carries its token. The timer closes fd 4 (accd's lock) first:
  a copy of it would block `acc -D stop`, restarts and the installer until the timer exits. Close it with
  `exec 4>&-` inside the subshell; mksh leaves the descriptor open for a `4>&-` on the subshell itself.
- Active only when the level is a percentage (pause_capacity <= 100) and the hold state reads Idle, so devices
  whose pause already discharges the battery (input_suspend as the only switch) are unaffected.

State is in `/dev/.vr25/acc/.state` (CHARGE, Idle, Discharging, DRAIN); events in `acc-data/logs/guard.log`.
On a device using the guard, set `allow_idle_above_pcap=true` to turn off the older `xIdle` logic.

## Tests

    sh tests/guard-test.sh                 # bash or mksh; 22 cases with a fake battery and virtual time

On a phone, push `tests/guard-test.sh` and `install/guard.sh` to one directory and run
`PATH=/dev/.vr25/busybox:$PATH sh guard-test.sh ./guard.sh` in the background (about 2 minutes).

## Deploy

    tools/deploy.sh [adb-serial]           # backs up, installs HEAD, keeps `acc -b` rollback

Do not wrap it in a short `timeout`: stopping the old daemon re-enables charging until the new one is up, so an
interrupted deploy leaves the phone charging with no controller.

If an install hangs, something still holds accd's lock (`/dev/.vr25/acc/acc.lock`). Look for orphaned `accd.sh`
processes with PPID 1 (`ps -A -o PID,PPID,ARGS | grep accd.sh`); they and their `sleep` children need `kill -9`,
because mksh defers a plain `kill` until the foreground child ends.

## Known gaps

- `module.prop` `updateJson` and `acc -u` still point at upstream; do not run `acc -u` on a device running this build.
- The README default-config block is not regenerated (build.sh needs `zip` and `markdown`).
- Stopping accd writes stale defaults back to `usb/current_max` and `usb/input_current_limit` (upstream behavior);
  the charger service restores them within seconds.
