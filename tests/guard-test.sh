#!/bin/sh
# Tests for install/guard.sh with a fake battery (files, stubbed switches, virtual time).
# Runs under bash or mksh (Android's /system/bin/sh). usage: sh tests/guard-test.sh [guard.sh]
#   on a phone: push tests/ and install/guard.sh, then: sh guard-test.sh ./guard.sh
# The suite is run with `set -u`, as accd runs with `set -eu`.

set -u

GUARD=${1:-${0%/*}/../install/guard.sh}
BASE=${TEST_TMP:-/tmp}/guard-test.$$
PASS=0
FAIL=0


# ---- fake battery ----

discharging() {
  [ "$(cat $T/sys/input_suspend)" = 1 ] && [ "${BROKEN_IS-0}" != 1 ] && return 0
  [ -f $T/sys/charging_enabled ] && [ "$(cat $T/sys/charging_enabled)" = 0 ] && return 0
  return 1
}

flip_sw() {
  flip=$1
  set -- ${chargingSwitch[@]-}
  [ -f "${1:-//}" ] || return 2
  if [ "$flip" = on ]; then echo "$2" > "$1"; else echo "$3" > "$1"; fi
}

not_charging() {
  flip=
  case "${1-}" in
    Discharging) discharging;;
    *) ! discharging;;
  esac
}

# -1% every 300 s of discharge; SIM_RATE=0 freezes the level
sim_step() {
  if discharging; then
    DRAINED=$((DRAINED + $1 * ${SIM_RATE-1}))
    while [ $DRAINED -ge 300 ]; do
      DRAINED=$((DRAINED - 300))
      echo $(( $(cat $battCapacity) - 1 )) > $battCapacity
    done
  fi
}

sleep() {
  VNOW=$((VNOW + ${1:-1}))
  sim_step ${1:-1}
}

date() {
  case "${1-}" in
    +%s) echo $VNOW;;
    *) echo "01-01 00:00:00";;
  esac
}

setup() {
  T=$BASE/$1
  rm -rf $T
  mkdir -p $T/tmp $T/data/logs $T/sys
  TMPDIR=$T/tmp
  dataDir=$T/data
  battCapacity=$T/sys/capacity
  temp=$T/sys/temp
  echo 67 > $battCapacity
  echo 300 > $temp
  echo 0 > $T/sys/input_suspend
  echo 3000000 > $T/sys/ccc
  echo 3000000 > $T/sys/constant_charge_current
  printf '%s\n' \
    "$T/sys/input_suspend 0 1" \
    "$T/sys/ccc 3000000 0" \
    "$T/sys/test_mode 2 1" \
    "$T/sys/constant_charge_current 3000000 0" > $TMPDIR/ch-switches
  echo "$T/sys/constant_charge_current::v000::3000000" > $TMPDIR/ch-curr-ctrl-files
  capacity=(5 101 60 65 false)
  temperature=(45 50 40 55)
  capacityGuard=auto
  chargingSwitch=($T/sys/ccc 3000000 0 --)
  _status=Idle
  accState=
  drainNextTry=0
  drainMaxSec=21600
  drainDeadmanSec=600   # real seconds; tests that exercise the timer set 1
  VNOW=1000000
  DRAINED=0
  SIM_RATE=1
  BROKEN_IS=0
  flip=
  . $GUARD
}


# ---- assertions (each test runs in a subshell, so exit ends only that test) ----

eq() {
  [ "$1" = "$2" ] || { echo "    FAIL: $3 (got [$1], want [$2])"; exit 1; }
}

has() {
  grep -q "$2" "$1" 2>/dev/null || { echo "    FAIL: $1 lacks [$2]"; exit 1; }
}

# run drain ticks until the drain ends (or give up after $1 ticks)
run_drain() {
  local n=0
  while [ "$accState" = DRAIN ] && [ $n -lt $1 ]; do
    drain_tick
    sleep 3
    n=$((n + 1))
  done
}


# ---- tests ----

t_drain_to_target() {
  guard_due || exit 1
  eq "$guardHi/$guardLo" "67/64" "auto limits"
  drain_start || exit 1
  eq "$accState" DRAIN "state after start"
  eq "$(cat $T/sys/input_suspend)" 1 "input cut"
  has $TMPDIR/.state DRAIN
  run_drain 5000
  eq "$accState" "" "state after drain"
  eq "$(guard_cap)" 64 "released at LO"
  eq "$(cat $T/sys/input_suspend)" 0 "input restored"
  [ ! -f $TMPDIR/.draining ] || { echo "    FAIL: marker left"; exit 1; }
  has $dataDir/logs/guard.log "DRAIN start"
  has $dataDir/logs/guard.log "DRAIN end (target)"
}

t_not_due_below_hi() {
  echo 66 > $battCapacity
  ! guard_due || { echo "    FAIL: due at 66"; exit 1; }
}

t_not_due_when_not_idle() {
  _status=Discharging
  ! guard_due || { echo "    FAIL: due while discharging"; exit 1; }
}

t_off() {
  capacityGuard=off
  echo 90 > $battCapacity
  ! guard_due || { echo "    FAIL: due when off"; exit 1; }
}

t_voltage_mode_is_off() {
  capacity=(5 101 3800 4100 false)
  ! guard_due || { echo "    FAIL: due in voltage mode"; exit 1; }
}

t_limits_must_clear_resume() {
  capacityGuard=70-55
  ! guard_limits || { echo "    FAIL: LO below resume accepted"; exit 1; }
  capacityGuard=60-70
  ! guard_limits || { echo "    FAIL: LO above HI accepted"; exit 1; }
  capacityGuard=junk
  ! guard_limits || { echo "    FAIL: junk accepted"; exit 1; }
}

t_explicit_limits() {
  capacityGuard=63-62
  echo 63 > $battCapacity
  guard_due || exit 1
  eq "$guardHi/$guardLo" "63/62" "explicit limits"
  drain_start || exit 1
  run_drain 5000
  eq "$accState" "" "state after drain"
  eq "$(guard_cap)" 62 "released at LO"
  eq "$(cat $T/sys/input_suspend)" 0 "input restored"
  has $TMPDIR/.state Idle
}

t_limits_need_hysteresis() {
  capacityGuard=63-63
  ! guard_limits || { echo "    FAIL: LO = HI accepted"; exit 1; }
  echo 63 > $battCapacity
  ! guard_due || { echo "    FAIL: due with LO = HI"; exit 1; }
}

t_deadline() {
  SIM_RATE=0
  drainMaxSec=100
  drain_start || exit 1
  run_drain 5000
  eq "$accState" "" "state"
  eq "$(cat $T/sys/input_suspend)" 0 "input restored"
  has $dataDir/logs/guard.log "DRAIN end (deadline)"
}

t_stop_file() {
  SIM_RATE=0
  drain_start || exit 1
  touch $TMPDIR/.stopdrain
  drain_tick
  eq "$accState" "" "state"
  eq "$(cat $T/sys/input_suspend)" 0 "input restored"
  has $dataDir/logs/guard.log "DRAIN end (stop)"
}

t_hot_battery_ends_drain() {
  SIM_RATE=0
  drain_start || exit 1
  echo 520 > $temp
  drain_tick
  eq "$accState" "" "state"
  has $dataDir/logs/guard.log "DRAIN end (temp)"
}

t_restore_is_idempotent() {
  drain_restore nothing
  eq "$accState" "" "state"
  eq "$(cat $T/sys/input_suspend)" 0 "untouched"
}

t_restore_after_a_crash() {
  # a previous daemon died mid-drain: marker present, input still cut
  echo "$T/sys/input_suspend 0 1" > $TMPDIR/.draining
  echo 1 > $T/sys/input_suspend
  drain_restore start
  eq "$(cat $T/sys/input_suspend)" 0 "input restored"
  [ ! -f $TMPDIR/.draining ] || { echo "    FAIL: marker left"; exit 1; }
}

t_deadman_restores() {
  SIM_RATE=0
  drainDeadmanSec=1
  drain_start || exit 1
  drain_unstick
  eq "$(cat $T/sys/input_suspend)" 0 "input restored"
  [ ! -f $TMPDIR/.draining ] || { echo "    FAIL: marker left"; exit 1; }
  has $dataDir/logs/guard.log "DRAIN end (deadman)"
}

t_deadman_timer_fires() {
  # real time: the detached timer must undo a drain that nobody ended
  SIM_RATE=0
  drainDeadmanSec=1
  drain_start || exit 1
  eq "$(cat $T/sys/input_suspend)" 1 "input cut"
  command sleep 3
  eq "$(cat $T/sys/input_suspend)" 0 "timer restored the input"
  [ ! -f $TMPDIR/.draining ] || { echo "    FAIL: marker left"; exit 1; }
}

t_deadman_is_cancelled_by_a_normal_end() {
  SIM_RATE=0
  drainDeadmanSec=1
  drain_start || exit 1
  drain_restore test
  echo 1 > $T/sys/input_suspend      # someone else cuts the input after the drain ended
  command sleep 3
  eq "$(cat $T/sys/input_suspend)" 1 "a cancelled timer must not touch the switch"
}

t_timer_does_not_hold_the_daemon_lock() {
  # accd holds its lock on fd 4 (acquire-lock.sh); a detached timer that keeps a copy blocks
  # `acc -D stop`, restarts and the installer until it exits, which is up to 6 hours
  SIM_RATE=0
  drainDeadmanSec=30
  : > $T/lock
  exec 4<>$T/lock
  flock -n 0 <&4 || { echo "    FAIL: cannot take the test lock"; exit 1; }   # as acquire-lock.sh does
  drain_start || exit 1
  exec 4>&-
  # a new open file description conflicts only while some process still holds the old one
  flock -n 0 < $T/lock || { echo "    FAIL: the timer still holds the lock"; exit 1; }
}

t_old_timer_leaves_a_newer_drain_alone() {
  SIM_RATE=0
  drainDeadmanSec=1
  drain_start || exit 1
  drain_restore first
  VNOW=$((VNOW + 5))                 # a later start time gives the new drain its own token
  drainDeadmanSec=600
  drain_start || exit 1
  command sleep 3                    # the first drain's timer wakes up in here
  eq "$(cat $T/sys/input_suspend)" 1 "the first timer must not end the second drain"
  eq "$accState" DRAIN "state"
}

t_falls_back_to_a_working_switch() {
  BROKEN_IS=1
  echo 1 > $T/sys/charging_enabled
  echo "$T/sys/charging_enabled 1 0" >> $TMPDIR/ch-switches
  drain_start || exit 1
  eq "$(cat $T/sys/input_suspend)" 0 "failed candidate restored"
  eq "$(cat $T/sys/charging_enabled)" 0 "working candidate cut"
  eq "$(cat $dataDir/drain-switch)" "$T/sys/charging_enabled 1 0" "cached"
  run_drain 5000
  eq "$(cat $T/sys/charging_enabled)" 1 "working candidate restored"
}

t_cached_switch_is_tried_first() {
  echo 1 > $T/sys/charging_enabled
  echo "$T/sys/charging_enabled 1 0" >> $TMPDIR/ch-switches
  echo "$T/sys/charging_enabled 1 0" > $dataDir/drain-switch
  drain_start || exit 1
  eq "$(cat $T/sys/charging_enabled)" 0 "cached switch used"
  eq "$(cat $T/sys/input_suspend)" 0 "other switch untouched"
}

t_no_working_switch_backs_off() {
  BROKEN_IS=1
  drain_start && { echo "    FAIL: started without a working switch"; exit 1; }
  eq "$accState" "" "state"
  eq "$(cat $T/sys/input_suspend)" 0 "candidate restored"
  ! guard_due || { echo "    FAIL: retried at once"; exit 1; }
  VNOW=$((VNOW + 3700))
  guard_due || { echo "    FAIL: no retry after the back-off"; exit 1; }
}

t_never_uses_the_hold_switch_or_current_files() {
  chargingSwitch=($T/sys/input_suspend 0 1 --)
  echo "$T/sys/input_suspend::v000::500000" > $TMPDIR/ch-curr-ctrl-files
  drain_start && { echo "    FAIL: used the hold switch / a current file"; exit 1; }
  eq "$(cat $T/sys/input_suspend)" 0 "untouched"
}

t_apply_on_plug_ignores_other_background_jobs() {
  # force_off is a background loop that outlives apply_on_plug; a bare `wait` made the main loop sleep until the
  # level fell below resume_capacity (seen on 2026-11-04: no guard for five days)
  MF=${GUARD%/*}/misc-functions.sh
  [ -f $MF ] || { echo "    skip: $MF not found"; return 0; }
  eval "$(sed -n '/^apply_on_plug() {$/,/^}$/p' $MF)"
  write() { command sleep 0.3 2>/dev/null || command sleep 1; }
  TMPDIR=$T
  applyOnPlug=("$T/sys/input_suspend::1::0")
  maxChargingVoltage=()
  maxChargingCurrent=()
  command sleep 20 &
  bg=$!
  start=$(command date +%s)   # `date` is the suite's virtual clock
  apply_on_plug
  took=$(( $(command date +%s) - start ))
  kill $bg 2>/dev/null || :
  [ $took -lt 5 ] || { echo "    FAIL: apply_on_plug waited $took s for an unrelated background job"; exit 1; }
}


# ---- runner ----

for t in ${ONLY:-$(sed -n 's/^\(t_[a-z_]*\)() {$/\1/p' $0)}; do
  if ( setup $t; $t ); then
    PASS=$((PASS + 1))
    echo "ok   $t"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL $t"
  fi
done

rm -rf $BASE
echo
echo "$PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
