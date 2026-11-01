# Capacity guard (DRAIN state)
# Copyright 2025, aar0u
# License: GPLv3+
#
# An idle ("hold") switch keeps the charger from charging the battery, but the level can still
# creep up. When capacity reaches guardHi while holding, cut the charger input with a switch that
# discharges the battery (DRAIN) until capacity falls to guardLo, then hold again.
#
# capacityGuard=auto|off|HI-LO    auto: HI = pause_capacity + 2, LO = pause_capacity - 1
#
# usage: . $0 (functions only)


accState=${accState-}
drainMaxSec=${drainMaxSec-21600}   # one drain never lasts longer than 6 h
drainNextTry=${drainNextTry-0}
drainStart=${drainStart-0}
guardHi=${guardHi-0}
guardLo=${guardLo-0}


guard_cap() {
  cat $battCapacity
}


guard_log() {
  local f=$dataDir/logs/guard.log
  mkdir -p ${f%/*} 2>/dev/null || :
  echo "$(date '+%m-%d %H:%M:%S') $*" >> $f 2>/dev/null || :
  [ $(du -k $f 2>/dev/null | cut -f 1) -lt 256 ] || : > $f
}


state_set() {
  echo "$1" > $TMPDIR/.state 2>/dev/null || :
}


# set guardHi and guardLo; fail if the guard is off or the limits make no sense
guard_limits() {
  local g=${capacityGuard-auto}
  [ ${capacity[3]} -le 100 ] || return 1
  case "$g" in
    off|false) return 1;;
    auto|"") guardHi=$((capacity[3] + 2)); guardLo=$((capacity[3] - 1));;
    [0-9]*-[0-9]*) guardHi=${g%-*}; guardLo=${g#*-};;
    *) return 1;;
  esac
  # LO below HI: with LO = HI a drain would end the moment it starts, and start again on the next loop
  [ $guardLo -lt $guardHi ] && [ $guardLo -gt ${capacity[2]} ] && [ $guardHi -le 100 ]
}


# true if the battery is held (idle) above the guard's upper limit
guard_due() {
  [ "${_status-}" = Idle ] || return 1
  [ $(date +%s) -ge $drainNextTry ] || return 1
  guard_limits || return 1
  [ $(guard_cap) -ge $guardHi ]
}


# candidate switches that can discharge the battery, best first: the last used one, then input_suspend, then the rest
drain_candidates() {
  local all=
  : > $TMPDIR/.drain-cand
  [ ! -f $dataDir/drain-switch ] || cat $dataDir/drain-switch >> $TMPDIR/.drain-cand
  # single-switch entries only, matched on the file name (parent directories say nothing about what a node does)
  all=$(awk 'NF == 3 { n = split($1, p, "/"); b = p[n] }
    NF == 3 && b ~ /input_suspend|charging_enabled|charge_enabled|enable_charg|charge_disable|disable_charg|charger_control|charging_suspend|charge_suspend|force_[a-z_]*suspend|op_disable_charge/ \
      && b !~ /current|voltage|temp|level|limit|cool/' $TMPDIR/ch-switches 2>/dev/null || :)
  { echo "$all" | grep input_suspend || :; echo "$all" | grep -v input_suspend || :; } \
    | grep . >> $TMPDIR/.drain-cand || :
}


# cut the input with switch "$@" and check that the battery really discharges; undo if not
drain_try() {
  (chargingSwitch=("$@")
  flip_sw off && _STI=10 not_charging Discharging) && return 0
  (chargingSwitch=("$@"); flip_sw on) 2>/dev/null || :
  return 1
}


drain_start() {

  local spec=
  local hold=${chargingSwitch[0]-}

  drain_candidates

  while read -r spec; do
    set -- $spec
    [ -f "${1-//}" ] || continue
    [ "$1" != "$hold" ] || continue
    ! grep -q "^$1::" $TMPDIR/ch-curr-ctrl-files $TMPDIR/ch-volt-ctrl-files 2>/dev/null || continue
    if drain_try $spec < /dev/null; then
      drainStart=$(date +%s)
      # line 1: switch; line 2: token that ties the detached timer to this drain
      printf '%s\n%s\n' "$spec" "$drainStart" > $TMPDIR/.draining
      echo "$spec" > $dataDir/drain-switch
      accState=DRAIN
      drain_arm_deadman
      state_set DRAIN
      guard_log "DRAIN start cap=$(guard_cap) hi=$guardHi lo=$guardLo sw=[$spec]"
      return 0
    fi
  done < $TMPDIR/.drain-cand

  drainNextTry=$(( $(date +%s) + 3600 ))
  guard_log "DRAIN not started: no verified discharging switch (cap=$(guard_cap)); retry in 1 h"
  return 1
}


# a drain that outlives its daemon (e.g., SIGKILL, which skips the exit handler) is undone by this detached timer;
# it acts only if the marker still carries its own token, so a drain that ended, or a newer one, is left alone
drain_arm_deadman() {
  local token=$drainStart
  # fd 4 is accd's lock (acquire-lock.sh); a copy in this timer would block `acc -D stop`, restarts and the installer.
  # Close it with exec inside the subshell: mksh keeps the fd open for a `4>&-` on the subshell itself.
  (exec 4>&-
  command sleep ${drainDeadmanSec:-$((drainMaxSec + 120))}
  [ "$(sed -n 2p $TMPDIR/.draining 2>/dev/null)" != "$token" ] || drain_unstick) < /dev/null > /dev/null 2>&1 &
}


drain_unstick() {
  local spec=$(sed -n 1p $TMPDIR/.draining 2>/dev/null || :)
  [ -z "$spec" ] || (chargingSwitch=($spec); flip_sw on) 2>/dev/null || :
  rm -f $TMPDIR/.draining 2>/dev/null || :
  guard_log "DRAIN end (deadman)"
}


# end a drain ($1: reason); safe to call when no drain is running
drain_restore() {

  local spec=

  [ -f $TMPDIR/.draining ] || { accState=; return 0; }

  spec=$(sed -n 1p $TMPDIR/.draining)
  (chargingSwitch=($spec); flip_sw on) < /dev/null 2>/dev/null || :
  rm -f $TMPDIR/.draining $TMPDIR/.stopdrain 2>/dev/null || :
  accState=
  state_set Idle
  guard_log "DRAIN end (${1-restore}) cap=$(guard_cap)"
}


drain_tick() {

  local cap=$(guard_cap)
  local why=

  if [ ! -f $TMPDIR/.draining ]; then why=marker-lost
  elif [ $cap -le $guardLo ]; then why=target
  elif [ $cap -le ${capacity[2]} ]; then why=floor
  elif [ $(( $(date +%s) - drainStart )) -ge $drainMaxSec ]; then why=deadline
  elif [ -f $TMPDIR/.stopdrain ]; then why=stop
  elif [ $(cat $temp) -ge $(( ${temperature[1]} * 10 )) ]; then why=temp
  else return 0
  fi

  drain_restore $why
}
