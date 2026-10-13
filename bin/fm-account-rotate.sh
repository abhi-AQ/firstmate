#!/usr/bin/env bash
# fm-account-rotate.sh - moves a running worker off a pooled account that hit
# its usage limit.
#
# Usage: fm-account-rotate.sh hint <state-dir> <task-id>
#        fm-account-rotate.sh tick
#
# docs/configuration.md "Worker account pin" owns the operator contract for an
# account pool (several roots in config/claude-account or config/codex-account);
# bin/fm-worker-account-lib.sh owns parsing, ranking, the limit records, and
# the sign-in check. This script owns only what happens to a worker already
# running on a pool account when that account runs out.
#
#   hint  Written by a pooled Claude worker's StopFailure hook, which fires only
#         for a turn that ended on a rate_limit or billing_error API failure.
#         Records state/<id>.account-limit and exits 0, so it can never break
#         Claude's own lifecycle.
#   tick  Run by the watcher on a bounded cadence (FM_ACCOUNT_ROTATE_SECS). For
#         each ship or scout in this home whose recorded harness is claude or
#         codex and whose recorded account= is a member of the home's current
#         pool (members signed in to one account share its limit record), with no declared stop (done, failed, needs-decision, blocked,
#         paused, captain-held) as its latest status and not provably busy:
#           - Limit evidence is a hint, or a quota-axi reading of that account
#             that is exhausted. A hint whose account reads measured headroom
#             was a transient rejection and is dropped.
#           - The account gets a limit record until its reading's earliest
#             reset, or FM_ACCOUNT_POOL_BACKOFF_SECS when that is unknown, so no
#             spawn or relaunch picks it meanwhile.
#           - When another pool account qualifies, the worker is relaunched
#             through bin/fm-control.sh relaunch (local copy and brief carry
#             over) and fm-spawn's own pool selection picks the account.
#           - When none qualifies, the worker waits (state/<id>.account-wait).
#             Once its own account is usable again it is told to continue,
#             keeping its conversation; once another account is usable first it
#             is relaunched there.
#         A task is relaunched, or reported unmovable, at most once per
#         FM_ACCOUNT_ROTATE_MIN_GAP_SECS.
#         Each line printed on stdout is one wake reason for the watcher:
#           check: <id> moved to another account after a usage limit (<from> -> <to>)
#           check: <id> could not move off its exhausted account: <detail>
#           check: account pool <harness> is out of usage; <n> worker(s) waiting until <reset>; they resume on their own
#         The pool notice prints once per exhaustion episode
#         (state/account-pool/<harness>.notice), cleared when a worker resumes.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${1:-}" in
  hint)
    [ "$#" -eq 3 ] || exit 0
    case "$3" in '' | *[!A-Za-z0-9._-]*) exit 0 ;; esac
    [ -d "$2" ] && date +%s > "$2/$3.account-limit" 2>/dev/null
    exit 0
    ;;
  tick) ;;
  -h | --help)
    sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    echo "usage: fm-account-rotate.sh hint <state-dir> <task-id> | tick" >&2
    exit 2
    ;;
esac

if [ -z "${FM_HOME:-}" ] || [ ! -d "$FM_HOME" ]; then
  echo "error: fm-account-rotate.sh tick needs FM_HOME naming an existing firstmate home" >&2
  exit 1
fi
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
BACKOFF=${FM_ACCOUNT_POOL_BACKOFF_SECS:-3600}
MIN_GAP=${FM_ACCOUNT_ROTATE_MIN_GAP_SECS:-300}

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-worker-account-lib.sh
. "$SCRIPT_DIR/fm-worker-account-lib.sh"
export FM_WORKER_ACCOUNT_STATE_DIR=$STATE

iso() {
  date -u -r "$1" +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%MZ
}

mtime() {
  perl -e 'print +(stat shift)[9] // 0' "$1"
}

# earliest <a> <b>: the smaller epoch, ignoring an empty or non-numeric one.
earliest() {
  case "$2" in '' | *[!0-9]*) printf '%s\n' "$1"; return ;; esac
  if [ -z "$1" ] || [ "$2" -lt "$1" ]; then printf '%s\n' "$2"; else printf '%s\n' "$1"; fi
}

# usable <class>: a probe class a launch may select.
usable() {
  case "$1" in measured | unmeasured) return 0 ;; *) return 1 ;; esac
}

# relaunch <id> <harness> <from-account>: moves the worker; prints its wake reason.
relaunch() {
  local id=$1 harness=$2 from=$3 out to
  touch "$STATE/$id.account-rotated"
  if out=$(FM_HOME=$FM_HOME "$SCRIPT_DIR/fm-control.sh" "$id" relaunch --note \
    "The $harness account this task ran on hit its usage limit, so Firstmate relaunched it on another account from this home's pool. Continue the task from the local copy." 2>&1); then
    to=$(fm_meta_get "$STATE/$id.meta" account)
    rm -f "${STATE:?}/$id.account-wait" "$STATE/$id.account-limit" "$STATE/account-pool/$harness.notice"
    printf 'check: %s moved to another account after a usage limit (%s -> %s)\n' "$id" "$from" "$to"
  else
    printf 'check: %s could not move off its exhausted account: %s\n' "$id" "$(printf '%s\n' "$out" | grep -m1 . | cut -c1-300)"
  fi
}

# Per-harness waiting tallies for the pool notice (bash 3.2 has no associative
# arrays, and only claude and codex pool).
claude_waiting=0 claude_reset='' codex_waiting=0 codex_reset=''

for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  id=${meta##*/}
  id=${id%.meta}
  case "$id" in '' | *[!A-Za-z0-9._-]*) continue ;; esac
  case "$(fm_meta_get "$meta" kind)" in ship | scout) ;; *) continue ;; esac
  harness=$(fm_meta_get "$meta" harness)
  case "$harness" in claude | codex) ;; *) continue ;; esac
  account=$(fm_meta_get "$meta" account)
  [ -n "$account" ] || continue
  pool=$(fm_worker_account_resolve "$harness" "$CONFIG" 2>/dev/null) || continue
  [ "$pool" != "${pool%%$'\n'*}" ] || continue
  line=$(printf '%s\n' "$pool" | awk -F '\t' -v a="$account" '$1 == a { print; exit }')
  [ -n "$line" ] || continue
  root=$(printf '%s\n' "$line" | cut -f2)

  hint="$STATE/$id.account-limit"
  wait_marker="$STATE/$id.account-wait"
  verb=$(status_line_verb "$(last_status_line "$STATE/$id.status")")
  case "$verb" in
    done | failed | needs-decision | blocked | paused | captain-held)
      rm -f "${hint:?}"
      continue
      ;;
  esac
  verdict=$(fm_busy_classify_meta "$meta" "$id" "$STATE")
  [ "${verdict%% *}" != busy ] || continue

  probe=$(fm_worker_account_pool_probe "$harness" "$root")
  class=${probe%%$'\t'*}
  reset=${probe##*$'\t'}
  if [ -f "$hint" ]; then
    rm -f "${hint:?}"
    if [ "$class" != measured ]; then
      [ "$class" = limited ] || fm_worker_account_pool_mark_limited "$harness" "$root" "${reset:-$(($(date +%s) + BACKOFF))}"
      class=limited
    fi
  elif [ "$class" = exhausted ]; then
    fm_worker_account_pool_mark_limited "$harness" "$root" "${reset:-$(($(date +%s) + BACKOFF))}"
    class=limited
  fi

  if usable "$class"; then
    # Not limited now: a waiting worker resumes on its own account and keeps
    # its conversation.
    if [ -f "$wait_marker" ]; then
      if FM_HOME=$FM_HOME "$SCRIPT_DIR/fm-send.sh" "$id" \
        "The usage limit on your account has reset. Continue the task from where you stopped." >/dev/null 2>&1; then
        rm -f "${wait_marker:?}" "$STATE/account-pool/$harness.notice"
      fi
    fi
    continue
  fi

  [ $(($(date +%s) - $(mtime "$STATE/$id.account-rotated" 2>/dev/null || echo 0))) -ge "$MIN_GAP" ] || continue
  picked=$(fm_worker_account_pool_pick "$harness" "$harness" "$pool" 2>&1)
  rc=$?
  case "$rc" in
    0) relaunch "$id" "$harness" "$account" ;;
    75)
      # The pool's earliest reset, which is when this worker can next run.
      reset=$(fm_worker_account_pool_rank "$harness" "$pool" | awk -F '\t' '$3 ~ /^[0-9]+$/ { print $3 }' | sort -n | head -1)
      printf '%s\n' "$reset" > "$wait_marker"
      if [ "$harness" = claude ]; then
        claude_waiting=$((claude_waiting + 1))
        claude_reset=$(earliest "$claude_reset" "$reset")
      else
        codex_waiting=$((codex_waiting + 1))
        codex_reset=$(earliest "$codex_reset" "$reset")
      fi
      ;;
    *)
      touch "$STATE/$id.account-rotated"
      printf 'check: %s could not move off its exhausted account: %s\n' "$id" "$(printf '%s\n' "$picked" | grep -m1 . | cut -c1-300)"
      ;;
  esac
done

for harness in claude codex; do
  if [ "$harness" = claude ]; then
    waiting=$claude_waiting reset=$claude_reset
  else
    waiting=$codex_waiting reset=$codex_reset
  fi
  notice="$STATE/account-pool/$harness.notice"
  [ "$waiting" -gt 0 ] && [ ! -e "$notice" ] || continue
  { mkdir -p "$STATE/account-pool" && : > "$notice"; } || continue
  until=unknown
  [ -z "$reset" ] || until=$(iso "$reset")
  printf 'check: account pool %s is out of usage; %s worker(s) waiting until %s; they resume on their own\n' \
    "$harness" "$waiting" "$until"
done
exit 0
