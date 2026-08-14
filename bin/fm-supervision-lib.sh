# shellcheck shell=bash
# Shared "supervision missing" predicate.
# Usage: . bin/fm-supervision-lib.sh
#
# Reports whether a firstmate home needs supervision because it has in-flight
# work (a state/<id>.meta exists), an X-mode relay poll
# (state/x-watch.check.sh), or queued wakes, and whether its watcher has a fresh liveness beacon
# (state/.last-watcher-beat, touched every poll cycle, within the grace window).
# bin/fm-turnend-guard.sh uses the PID-strict fm_watcher_healthy from
# bin/fm-wake-lib.sh for its block decision. bin/fm-guard.sh uses the model-aware
# fm_watcher_supervision_verdict (also in bin/fm-wake-lib.sh), which owns what a
# live watcher process means per supervision model. The status fields here retain
# the beacon-age details used in their messages.

# Portable mtime; Linux stat lacks -f, macOS stat lacks -c.
fm_sup_stat_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# fm_supervision_status <state-dir> [grace-seconds]
# Populates, for the state dir at $1:
#   FM_SUP_IN_FLIGHT      count of state/*.meta (in-flight tasks)
#   FM_SUP_SOURCES        count of registered process-to-event sources
#   FM_SUP_NEEDED         true/false - in-flight work, an X-mode relay poll,
#                         queued wakes, or a registered event source (a source
#                         is a wait on an external process, not a task, so it has
#                         no metadata)
#   FM_SUP_WATCHER_FRESH  true/false - a watcher beacon within the grace window
#   FM_SUP_BEACON_DESC    human-readable beacon age, for banners ("never" if absent)
#   FM_SUP_QUEUE_PENDING  true/false - state/.wake-queue has unread records
# grace-seconds defaults via fm_guard_grace_seconds (bin/fm-wake-lib.sh): explicit
# FM_GUARD_GRACE wins, otherwise min(60x normalized-poll, FM_GUARD_GRACE_MAX) with
# a 3600s default ceiling so absurd poll intervals cannot suppress down-detection.
# Always returns 0; callers read the vars, or use fm_supervision_unhealthy below.
#
# Standalone fallback when wake-lib is not sourced: same fm_poll_seconds shape,
# fractional floor(poll*60) grace, and hard cap so status predicates stay usable
# without pulling wake-lib side effects.
fm_sup_default_grace() {
  local poll grace max
  if declare -F fm_guard_grace_seconds >/dev/null 2>&1; then
    fm_guard_grace_seconds
    return 0
  fi
  case "${FM_GUARD_GRACE:-}" in
    ''|*[!0-9]*) ;;
    *) printf '%s\n' "$FM_GUARD_GRACE"; return 0 ;;
  esac
  if declare -F fm_poll_seconds >/dev/null 2>&1; then
    poll=$(fm_poll_seconds)
  else
    # Mirror fm_poll_seconds: canonical base-10, ceiling, post-round positivity.
    poll=$(awk -v p="${FM_POLL:-15}" -v m="${FM_POLL_MAX_SECONDS:-86400}" 'BEGIN {
      if (m + 0 <= 0) m = 86400
      if (p ~ /[^0-9.]/ || p ~ /\..*\./ || p == "" || p ~ /^\./ || p ~ /\.$/) {
        print 15; exit
      }
      n = p + 0
      if (!(n > 0) || n > m) { print 15; exit }
      if (n == int(n)) { printf "%d\n", int(n); exit }
      s = sprintf("%.6f", n)
      sub(/0+$/, "", s)
      sub(/\.$/, "", s)
      if (!(s + 0 > 0) || (s + 0) > m) { print 15; exit }
      print s
    }')
  fi
  max=${FM_GUARD_GRACE_MAX:-3600}
  case "$max" in ''|*[!0-9]*) max=3600 ;; esac
  [ "$max" -gt 0 ] || max=3600
  case "$poll" in
    *[!0-9]*)
      grace=$(awk -v p="$poll" -v m="$max" 'BEGIN {
        g = int(p * 60)
        if (g < 1) g = 1
        if (g > m) g = m
        print g
      }')
      ;;
    *)
      grace=$(( 10#$poll * 60 ))
      [ "$grace" -ge 1 ] || grace=1
      [ "$grace" -le "$max" ] || grace=$max
      ;;
  esac
  printf '%s\n' "$grace"
}

fm_supervision_status() {
  local state=$1 grace=${2:-} meta source beat m age
  [ -n "$grace" ] || grace=$(fm_sup_default_grace)
  FM_SUP_IN_FLIGHT=0
  FM_SUP_NEEDED=false
  FM_SUP_WATCHER_FRESH=false
  FM_SUP_BEACON_DESC=never
  FM_SUP_QUEUE_PENDING=false

  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    FM_SUP_IN_FLIGHT=$((FM_SUP_IN_FLIGHT + 1))
  done
  FM_SUP_SOURCES=0
  for source in "$state"/procevent/*.source; do
    [ -e "$source" ] || continue
    FM_SUP_SOURCES=$((FM_SUP_SOURCES + 1))
  done
  [ -s "$state/.wake-queue" ] && FM_SUP_QUEUE_PENDING=true
  if [ "$FM_SUP_IN_FLIGHT" -gt 0 ] \
    || [ -f "$state/x-watch.check.sh" ] \
    || [ "$FM_SUP_SOURCES" -gt 0 ] \
    || [ "$FM_SUP_QUEUE_PENDING" = true ]; then
    FM_SUP_NEEDED=true
  fi

  beat="$state/.last-watcher-beat"
  if [ -e "$beat" ]; then
    m=$(fm_sup_stat_mtime "$beat")
    if [ -n "$m" ]; then
      age=$(( $(date +%s) - m ))
      FM_SUP_BEACON_DESC="${age}s ago"
      [ "$age" -lt "$grace" ] && FM_SUP_WATCHER_FRESH=true
    else
      # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
      FM_SUP_BEACON_DESC=unknown
    fi
  fi

  return 0
}

# fm_supervision_needed <state-dir> [grace-seconds]
# Exit 0 (true) exactly when the home needs a watcher.
fm_supervision_needed() {
  fm_supervision_status "$@"
  [ "$FM_SUP_NEEDED" = true ]
}

# fm_supervision_unhealthy <state-dir> [grace-seconds]
# Exit 0 (true) exactly when supervision is needed and no watcher has a fresh
# beacon. Exit 1 (false) otherwise.
fm_supervision_unhealthy() {
  fm_supervision_status "$@"
  [ "$FM_SUP_NEEDED" = true ] && [ "$FM_SUP_WATCHER_FRESH" = false ]
}
