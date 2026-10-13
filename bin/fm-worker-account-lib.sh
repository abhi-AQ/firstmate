#!/usr/bin/env bash
# fm-worker-account-lib.sh - the single owner of the opt-in per-home worker
# account pin: which runners can be pinned, how a pin file is parsed and
# resolved, the launch-time sign-in check under it, and the environment
# credentials a pinned Claude launch sheds.
#
# docs/configuration.md "Worker account pin" owns the operator-facing contract.
# Sourced by bin/fm-spawn.sh and bin/fm-control.sh.
#
# Pinnable runners, each a credential store inside a root its vendor lets a
# process select:
#   claude          CLAUDE_CONFIG_DIR     config/claude-account
#   codex           CODEX_HOME            config/codex-account
#   pi, pi-signed   PI_CODING_AGENT_DIR   config/pi-account
#
# The pin is opt-in: an absent file is no pin, and the launch keeps today's
# ambient behavior byte for byte. A present file must resolve, or the launch
# refuses; nothing falls back to an ambient or vendor-default login once a
# home has declared one. `ordinary` selects the vendor default: for Claude
# that is CLAUDE_CONFIG_DIR unset, because Claude reads $CLAUDE_CONFIG_DIR/
# .claude.json and keys its macOS Keychain entry to any CLAUDE_CONFIG_DIR that
# is set, even $HOME/.claude; for Pi it is $HOME/.pi/agent. Any other value is
# one absolute path to an existing readable, searchable directory. Firstmate
# never copies credentials or changes a global login. For Codex, ordinary is
# CODEX_HOME unset.
#
# Account pool: config/claude-account and config/codex-account may list
# several roots, one per line, each holding one signed-in account; `ordinary`
# may be one of them and is read through ~/.claude or ~/.codex. At each launch
# the pool member with the most measured headroom wins: quota-axi
# --profile-only reads each root's own credential file (never a Keychain), a
# reading is cached for FM_ACCOUNT_POOL_CACHE_SECONDS under state/account-pool/
# so a burst of spawns asks the vendor once, a root with a future limit record
# or an exhausted reading is skipped, a root quota-axi cannot measure ranks
# after every measured one, and the first ranked root whose sign-in check
# passes is selected. Ties keep file order. Limit records are keyed by account
# identity (Claude's oauthAccount.accountUuid, Codex's quota-axi account id),
# so two roots signed in to one account are limited together. When every
# member is out of usage the selection returns 75, like a capacity refusal, so
# the work stays queued; bin/fm-account-rotate.sh owns moving running workers.
#
# A Pi root can hold several provider identities, so config/pi-account names
# the root on line 1 and the providers that home may spend on line 2,
# separated by spaces. A pinned Pi launch must name its provider explicitly as
# --model <provider>/<id>, and that provider must be declared; Firstmate never
# guesses a provider for an unqualified model. The canonical launch also
# passes --provider <that provider>, because without it Pi may resolve a
# provider-prefixed model under another authenticated provider. A raw Pi
# launch command is launched verbatim and cannot receive that flag, so a home
# with config/pi-account refuses raw Pi launches. A raw Claude launch command
# runs after the pinned root and shed credentials are applied, so its own
# leading CLAUDE_CONFIG_DIR or shed-credential assignment would override the
# pin; a home with config/claude-account refuses such a command.
#
# The sign-in check asks the runner itself, with only HOME, PATH, TMPDIR,
# USER, LOGNAME, and the selected root in its environment, so a credential
# variable left in the caller cannot answer for a root that has no login:
#   Claude: `claude auth status`, which exits 0 only when signed in.
#   Codex:  `codex login status`, which exits 0 only when signed in.
#   Pi:     `pi auth check --provider <p> --json --no-refresh`; status "ready"
#           passes. `pi auth check` loads no extensions, so it answers
#           not_ready/provider_not_found for an extension-registered provider,
#           and a Pi without the command (before 0.84.1) prints no JSON. Both
#           fall through to `pi --list-models <p>`, which lists only the models
#           a root can authenticate; a row whose provider column is exactly
#           <p> passes. --no-refresh keeps the check from rewriting a root's
#           tokens while other workers use them.
# A pinned Claude launch also unsets the environment credentials Claude ranks
# above the root's stored login, so an ambient API key or token cannot outrank
# the pin. Pi ranks a root's stored credentials above environment variables,
# and the check refuses a provider the root has not stored, so a pinned Pi
# launch unsets nothing.

# shellcheck source=bin/fm-timeout-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"

FM_WORKER_ACCOUNT_CHECK_SECONDS=${FM_WORKER_ACCOUNT_CHECK_SECONDS:-30}
FM_ACCOUNT_POOL_CACHE_SECONDS=${FM_ACCOUNT_POOL_CACHE_SECONDS:-60}
FM_ACCOUNT_POOL_QUOTA_SECONDS=${FM_ACCOUNT_POOL_QUOTA_SECONDS:-20}
# The state directory pool readings and limit records live under; callers set
# it to their home's state/. Empty disables the cache and limit records.
FM_WORKER_ACCOUNT_STATE_DIR=${FM_WORKER_ACCOUNT_STATE_DIR:-}

# Credentials Claude Code ranks above the /login stored in its config root
# (code.claude.com/docs/en/authentication, "Authentication precedence"; the
# Claude Platform on AWS and Bedrock Mantle switches from
# code.claude.com/docs/en/env-vars).
FM_WORKER_ACCOUNT_CLAUDE_SHED="CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY CLAUDE_CODE_USE_ANTHROPIC_AWS CLAUDE_CODE_USE_MANTLE ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_PROFILE ANTHROPIC_FEDERATION_RULE_ID"

# fm_worker_account_file <harness>
# Prints the pin file name for a pinnable runner; returns 1 for any other.
fm_worker_account_file() {
  case "$1" in
  claude) printf '%s\n' claude-account ;;
  codex) printf '%s\n' codex-account ;;
  pi | pi-signed) printf '%s\n' pi-account ;;
  *) return 1 ;;
  esac
}

# fm_worker_account_read <harness> <file>
# Prints "declared<TAB>providers" for a valid pin, where declared is
# `ordinary` or the absolute path and providers is empty for Claude and Codex.
# A Claude or Codex pool prints one such line per root, in file order. The
# final newline is optional; any other control byte, including a CR, is
# malformed, and so is a repeated root inside a pool. Parses
# bytes before the shell can drop NULs or trailing newlines; paths are
# literal, never shell expressions. Returns 0 on success, 3 when the file does
# not exist, 4 when it cannot be inspected (one error already printed), 5 when
# it is not a readable regular file, and 6 when it is malformed.
fm_worker_account_read() {
  perl -MErrno=ENOENT -e '
    my ($harness, $f) = @ARGV;
    unless (lstat $f) {
      exit 3 if $! == ENOENT;
      print STDERR "error: cannot inspect configuration source at $f: $!\n";
      exit 4;
    }
    (-f $f && -r _) or exit 5;
    open(my $fh, "<", $f) or exit 5;
    my $body = do { local $/; <$fh> } // "";
    my $entry = qr{ordinary|/[^\x00-\x1f\x7f]*};
    if ($harness eq "claude" || $harness eq "codex") {
      $body =~ /\A(?:$entry\n)*$entry\n?\z/ or exit 6;
      my @roots = split /\n/, $body;
      if (@roots > 1) {
        my %seen;
        for (@roots) { exit 6 if $seen{$_}++; }
      }
      print join("\n", map { "$_\t" } @roots);
    } else {
      $body =~ /\A($entry)\n([A-Za-z0-9][A-Za-z0-9._-]*(?: +[A-Za-z0-9][A-Za-z0-9._-]*)*)\n?\z/ or exit 6;
      print $1, "\t", $2;
    }
  ' -- "$1" "$2"
}

# fm_worker_account_resolve <harness> <config-dir>
# Prints "declared<TAB>root<TAB>providers" for a valid pin, one line per pool
# root, where root is the directory the launch selects (empty for ordinary
# Claude or Codex, meaning the variable unset). Prints nothing and returns 0
# when the runner is not pinnable or the home has no pin. On refusal prints
# one error naming the file and returns 1.
fm_worker_account_resolve() {
  local harness=$1 config=$2 file cfg token rc line declared root fallback out=
  file=$(fm_worker_account_file "$harness") || return 0
  cfg="$config/$file"
  token=$(fm_worker_account_read "$harness" "$cfg")
  rc=$?
  case "$rc" in
  0) ;;
  3) return 0 ;;
  4) return 1 ;;
  5)
    echo "error: config/$file must be a readable regular file: $cfg" >&2
    return 1
    ;;
  *)
    if [ "$file" = pi-account ]; then
      echo "error: config/$file must hold 'ordinary' or one absolute path on line 1 and the providers this home may spend on line 2, separated by spaces, with no other lines or control characters: $cfg" >&2
    else
      echo "error: config/$file must hold 'ordinary' or one absolute path on a single line, or a pool of distinct entries of either kind one per line, with no control characters: $cfg" >&2
    fi
    return 1
    ;;
  esac
  # shellcheck disable=SC2088  # The fallbacks are literal text for the refusal.
  case "$harness" in
  claude) fallback='~/.claude with CLAUDE_CONFIG_DIR unset' ;;
  codex) fallback='~/.codex with CODEX_HOME unset' ;;
  *) fallback='~/.pi/agent' ;;
  esac
  while IFS= read -r line; do
    declared=${line%%$'\t'*}
    root=$declared
    if [ "$declared" = ordinary ]; then
      case "$harness" in
      claude | codex) root= ;;
      *) root="${HOME:?HOME is required to resolve an ordinary Pi account}/.pi/agent" ;;
      esac
    fi
    if [ -n "$root" ] && { [ ! -d "$root" ] || [ ! -r "$root" ] || [ ! -x "$root" ]; }; then
      echo "error: config/$file must name a readable, searchable existing directory (ordinary means $fallback): $cfg -> $root" >&2
      return 1
    fi
    out+=$(printf '%s\t%s\t%s' "$declared" "$root" "${line#*$'\t'}")$'\n'
  done <<< "$token"
  printf '%s' "$out"
}

# fm_worker_account_pi_provider <model>
# Prints the provider an explicit Pi --model <provider>/<id> names. Returns 1,
# silently, for anything else, so no caller can fall back to a guess.
fm_worker_account_pi_provider() {
  local model=$1
  case "$model" in
  */*)
    [ -n "${model%%/*}" ] && [ -n "${model#*/}" ] || return 1
    printf '%s\n' "${model%%/*}"
    ;;
  *) return 1 ;;
  esac
}

# fm_worker_account_check <harness> <declared> <root> <executable> [<provider>]
# Returns 0 only when the runner's own check says the selected root is signed
# in for this launch; otherwise prints one error and returns 1.
fm_worker_account_check() {
  local harness=$1 declared=$2 root=$3 executable=$4 provider=${5:-} out verdict name
  local -a clean=(env -i "HOME=${HOME:-}" "PATH=${PATH:-}")
  for name in TMPDIR USER LOGNAME; do
    [ -z "${!name:-}" ] || clean+=("$name=${!name}")
  done
  case "$harness" in
  claude)
    [ -z "$root" ] || clean+=("CLAUDE_CONFIG_DIR=$root")
    if fm_run_timed "$FM_WORKER_ACCOUNT_CHECK_SECONDS" "${clean[@]}" \
      "$executable" auth status >/dev/null 2>&1 </dev/null; then
      return 0
    fi
    if [ -n "$root" ]; then
      echo "error: config/claude-account pins Claude workers to $root, which is not signed in (claude auth status); sign in with CLAUDE_CONFIG_DIR=$root claude, then /login, or change the pin" >&2
    else
      echo "error: config/claude-account pins Claude workers to the ordinary account, which is not signed in (claude auth status); sign in with env -u CLAUDE_CONFIG_DIR claude, then /login, or change the pin" >&2
    fi
    return 1
    ;;
  codex)
    [ -z "$root" ] || clean+=("CODEX_HOME=$root")
    if fm_run_timed "$FM_WORKER_ACCOUNT_CHECK_SECONDS" "${clean[@]}" \
      "$executable" login status >/dev/null 2>&1 </dev/null; then
      return 0
    fi
    echo "error: config/codex-account pins Codex workers to ${root:-the ordinary account}, which is not signed in (codex login status); sign in with ${root:+CODEX_HOME=$root }codex login, or change the pin" >&2
    return 1
    ;;
  pi | pi-signed)
    clean+=("PI_CODING_AGENT_DIR=$root")
    out=$(fm_run_timed "$FM_WORKER_ACCOUNT_CHECK_SECONDS" "${clean[@]}" \
      "$executable" auth check --provider "$provider" --json --no-refresh 2>/dev/null </dev/null)
    verdict=$(printf '%s\n' "$out" | jq -r '
      if type != "object" or (has("status") | not) then "list"
      elif .status == "ready" then "ready"
      elif .status == "not_ready" and .reason == "provider_not_found" then "list"
      else "\(.status) \(.reason // "")"
      end' 2>/dev/null)
    case "${verdict:-list}" in
    ready) return 0 ;;
    list)
      if out=$(fm_run_timed "$FM_WORKER_ACCOUNT_CHECK_SECONDS" "${clean[@]}" \
        "$executable" --list-models "$provider" 2>/dev/null </dev/null) &&
        printf '%s\n' "$out" | awk -v p="$provider" 'NR > 1 && $1 == p { found = 1; exit } END { exit !found }'; then
        return 0
      fi
      verdict="no model listed for provider $provider"
      ;;
    esac
    echo "error: config/pi-account pins Pi workers to $declared, which is not signed in for provider '$provider' ($verdict); sign in with PI_CODING_AGENT_DIR=$root $harness, then /login, or change the pin" >&2
    return 1
    ;;
  esac
  return 0
}

# fm_worker_account_pool_measure_root <harness> <root>
# Prints the directory a pool reading uses: the root itself, or the vendor
# default for the ordinary account, whose launch leaves the variable unset.
fm_worker_account_pool_measure_root() {
  if [ -n "$2" ]; then
    printf '%s\n' "$2"
  else
    printf '%s/.%s\n' "${HOME:?HOME is required to read an ordinary pool account}" "$1"
  fi
}

# fm_worker_account_pool_cache_name <harness> <root>
# Prints a file-name-safe name for one root's cached reading.
fm_worker_account_pool_cache_name() {
  printf '%s-%s\n' "$1" "$(printf '%s' "$2" | cksum | awk '{print $1 "-" $2}')"
}

# fm_worker_account_pool_quota <harness> <root>
# Prints one profile-only quota-axi reading of the root's own credential file
# ({} when quota-axi is absent or prints no JSON object), reusing a cached
# reading younger than FM_ACCOUNT_POOL_CACHE_SECONDS. --full keeps the
# non-secret account identity; tokens are never printed.
fm_worker_account_pool_quota() {
  local harness=$1 root var cache='' age out=''
  root=$(fm_worker_account_pool_measure_root "$1" "$2")
  case "$harness" in
  claude) var=CLAUDE_CONFIG_DIR ;;
  *) var=CODEX_HOME ;;
  esac
  if [ -n "$FM_WORKER_ACCOUNT_STATE_DIR" ]; then
    cache="$FM_WORKER_ACCOUNT_STATE_DIR/account-pool/$(fm_worker_account_pool_cache_name "$harness" "$root").quota.json"
    if [ -f "$cache" ]; then
      age=$(($(date +%s) - $(perl -e 'print +(stat shift)[9]' "$cache")))
      if [ "$age" -ge 0 ] && [ "$age" -lt "$FM_ACCOUNT_POOL_CACHE_SECONDS" ]; then
        cat "$cache"
        return 0
      fi
    fi
  fi
  if command -v quota-axi >/dev/null 2>&1; then
    out=$(fm_run_timed "$FM_ACCOUNT_POOL_QUOTA_SECONDS" env "$var=$root" \
      quota-axi --provider "$harness" --profile-only --full --json 2>/dev/null </dev/null)
  fi
  printf '%s' "$out" | jq -e 'type == "object"' >/dev/null 2>&1 || out='{}'
  if [ -n "$cache" ] && mkdir -p "${cache%/*}" 2>/dev/null; then
    printf '%s\n' "$out" > "$cache.$$" && mv -f "$cache.$$" "$cache"
  fi
  printf '%s\n' "$out"
}

# fm_worker_account_pool_key <harness> <root>
# Prints the file-name-safe key a root's limit record uses: its account
# identity, else the root path, so duplicate logins share one record. Claude's
# identity is the non-secret oauthAccount.accountUuid in its own account
# record, which needs no vendor call; Codex's is the account id a quota-axi
# reading names.
fm_worker_account_pool_key() {
  local harness=$1 root identity='' record
  root=$(fm_worker_account_pool_measure_root "$1" "$2")
  if [ "$harness" = claude ]; then
    record="$root/.claude.json"
    [ -n "$2" ] || record="$HOME/.claude.json"
    identity=$(jq -r '.oauthAccount // {} | .accountUuid // .emailAddress // empty' "$record" 2>/dev/null)
  fi
  [ -n "$identity" ] || identity=$(fm_worker_account_pool_quota "$harness" "$2" |
    jq -r '(.providers // [])[0].account // {} | .accountId // .accountUuid // .email // empty' 2>/dev/null)
  if [ -n "$identity" ]; then
    fm_worker_account_pool_cache_name "$harness" "id:$identity"
  else
    fm_worker_account_pool_cache_name "$harness" "path:$root"
  fi
}

# fm_worker_account_pool_mark_limited <harness> <root> <reset-epoch>
# Records that the root's account is out of usage until <reset-epoch>, so
# selection skips it, and every root signed in to the same account, even when
# quota-axi cannot measure it; drops the root's cached reading.
fm_worker_account_pool_mark_limited() {
  local dir record
  [ -n "$FM_WORKER_ACCOUNT_STATE_DIR" ] || return 1
  dir="$FM_WORKER_ACCOUNT_STATE_DIR/account-pool"
  mkdir -p "$dir" || return 1
  record="$dir/$(fm_worker_account_pool_key "$1" "$2").limit"
  rm -f "${dir:?}/$(fm_worker_account_pool_cache_name "$1" "$(fm_worker_account_pool_measure_root "$1" "$2")").quota.json"
  printf '%s\t%s\n' "$3" "$(fm_worker_account_pool_measure_root "$1" "$2")" > "$record.$$" && mv -f "$record.$$" "$record"
}

# fm_worker_account_pool_probe <harness> <root>
# Prints "<class><TAB><headroom><TAB><reset-epoch>" for one pool root:
#   limited     a limit record whose reset is still in the future
#   exhausted   quota-axi reads an exhausted window or availability
#   measured    quota-axi reads headroom: the lowest known percent remaining
#   unmeasured  quota-axi cannot read the root (a Keychain-only login, no
#               quota-axi, an auth failure); the sign-in check decides
# reset-epoch is the earliest known reset of a limited or exhausted root.
fm_worker_account_pool_probe() {
  local harness=$1 root=$2 record reset
  if [ -n "$FM_WORKER_ACCOUNT_STATE_DIR" ]; then
    record="$FM_WORKER_ACCOUNT_STATE_DIR/account-pool/$(fm_worker_account_pool_key "$harness" "$root").limit"
    if [ -f "$record" ]; then
      reset=$(cut -f1 "$record" 2>/dev/null)
      case "$reset" in
      '' | *[!0-9]*) ;;
      *)
        if [ "$reset" -gt "$(date +%s)" ]; then
          printf 'limited\t0\t%s\n' "$reset"
          return 0
        fi
        ;;
      esac
      rm -f "${record:?}"
    fi
  fi
  fm_worker_account_pool_quota "$harness" "$root" | jq -r '
    def epoch: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
    (.providers // [])[0] as $p |
    if $p == null or (($p.state.status // "") | IN("fresh", "stale") | not) then "unmeasured\t\t"
    else
      [$p.quotaSemantics.effectiveAvailability[]? | select(.status == "known")] as $known |
      [$p.windows[]? | select(.resetsAt != null)] as $windows |
      if ([$p.quotaSemantics.effectiveAvailability[]? | select(.runway.status == "exhausted_now")] | length) > 0
         or ($known | any(.effectivePercentRemaining <= 0))
      then
        ([$windows[] | select((.percentRemaining // 1) <= 0)] | if length > 0 then . else $windows end
          | map(.resetsAt | epoch | floor) | min) as $reset |
        "exhausted\t0\t\($reset // "")"
      elif ($known | length) > 0 then "measured\t\($known | map(.effectivePercentRemaining) | min)\t"
      else "unmeasured\t\t"
      end
    end' 2>/dev/null || printf 'unmeasured\t\t\n'
}

# fm_worker_account_pool_rank <harness> <resolved-lines>
# Prints "<class><TAB><headroom><TAB><reset><TAB><declared><TAB><root>" for
# every pool root: measured roots with headroom first, most headroom first,
# then unmeasured roots, then limited and exhausted ones; ties keep file order.
fm_worker_account_pool_rank() {
  local harness=$1 lines=$2 line declared root probe class headroom tier n=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    n=$((n + 1))
    declared=${line%%$'\t'*}
    root=${line#*$'\t'}
    root=${root%%$'\t'*}
    probe=$(fm_worker_account_pool_probe "$harness" "$root")
    class=${probe%%$'\t'*}
    headroom=${probe#*$'\t'}
    headroom=${headroom%%$'\t'*}
    case "$class" in
    measured) tier=$(awk -v h="$headroom" 'BEGIN { print (h > 0) ? 1 : 3 }') ;;
    unmeasured) tier=2 ;;
    *) tier=3 ;;
    esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$tier" "${headroom:-0}" "$n" "$probe" "$declared" "$root"
  done <<< "$lines" | sort -t "$(printf '\t')" -k1,1n -k2,2gr -k3,3n | cut -f4-
}

# fm_worker_account_pool_pick <harness> <executable> <resolved-lines>
# Prints "declared<TAB>root" for the best-ranked pool root whose sign-in check
# passes. When none qualifies prints one error and returns 75 if any root is
# out of usage, naming the earliest reset, else 1.
fm_worker_account_pool_pick() {
  local harness=$1 executable=$2 lines=$3 line class reset declared root earliest='' limited=0 file
  file=$(fm_worker_account_file "$harness")
  # Split by hand: tab is IFS whitespace, so read would merge empty fields.
  while IFS= read -r line; do
    class=${line%%$'\t'*}
    line=${line#*$'\t'}
    line=${line#*$'\t'}
    reset=${line%%$'\t'*}
    line=${line#*$'\t'}
    declared=${line%%$'\t'*}
    root=${line#*$'\t'}
    case "$class" in
    '') continue ;;
    limited | exhausted)
      limited=1
      if [ -n "$reset" ] && { [ -z "$earliest" ] || [ "$reset" -lt "$earliest" ]; }; then
        earliest=$reset
      fi
      continue
      ;;
    esac
    if fm_worker_account_check "$harness" "$declared" "$root" "$executable" 2>/dev/null; then
      printf '%s\t%s\n' "$declared" "$root"
      return 0
    fi
  done <<< "$(fm_worker_account_pool_rank "$harness" "$lines")"
  if [ "$limited" = 1 ]; then
    if [ -n "$earliest" ]; then
      earliest=$(date -u -r "$earliest" +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -d "@$earliest" +%Y-%m-%dT%H:%MZ)
    else
      earliest=unknown
    fi
    echo "error: every signed-in account in config/$file is out of usage until at least $earliest; the launch waits rather than spending past a limit" >&2
    return 75
  fi
  echo "error: no account in config/$file is signed in; sign each root in or remove it from the pool" >&2
  return 1
}

# fm_worker_account_select <harness> <config-dir> <model> <executable> [<raw-command>]
# The whole launch-time decision. Prints nothing for an unpinned runner, so
# the caller keeps today's launch unchanged. For a pinned one prints
# "declared<TAB>root<TAB>provider", where provider is the Pi launch model's
# own (empty for Claude and Codex), after the model guard and the sign-in
# check pass; a pool chooses its root through fm_worker_account_pool_pick. On
# refusal prints one error and returns 1, or 75 when every pool root is out of
# usage. bin/fm-spawn.sh runs it before any endpoint exists, and
# bin/fm-control.sh before a relaunch stops the live agent.
fm_worker_account_select() {
  local harness=$1 config=$2 model=$3 executable=$4 raw=${5:-} selection declared root providers word guarded file provider='' rc
  selection=$(fm_worker_account_resolve "$harness" "$config") || return 1
  [ -n "$selection" ] || return 0
  declared=${selection%%$'\t'*}
  root=${selection#*$'\t'}
  providers=${root#*$'\t'}
  providers=${providers%%$'\n'*}
  root=${root%%$'\t'*}
  case "$harness" in
  claude | codex)
    file=$(fm_worker_account_file "$harness")
    guarded="CODEX_HOME"
    [ "$harness" = codex ] || guarded="CLAUDE_CONFIG_DIR $FM_WORKER_ACCOUNT_CLAUDE_SHED"
    for word in $raw; do
      case "$word" in
      [A-Za-z_]*=*)
        case " $guarded " in
        *" ${word%%=*} "*)
          echo "error: config/$file pins $harness workers, but the raw launch command sets ${word%%=*}, which would override the pinned account; remove ${word%%=*} from the raw command, or change or remove config/$file" >&2
          return 1
          ;;
        esac
        ;;
      *) break ;;
      esac
    done
    if [ "$selection" != "${selection%%$'\n'*}" ]; then
      selection=$(fm_worker_account_pool_pick "$harness" "$executable" "$selection")
      rc=$?
      [ "$rc" = 0 ] || return "$rc"
      printf '%s\t\n' "$selection"
      return 0
    fi
    ;;
  *)
    if [ -n "$raw" ]; then
      echo "error: config/pi-account pins Pi workers, and a raw Pi launch command runs verbatim, so it cannot carry the pinned --provider; launch with --harness $harness and --model <provider>/<id> instead" >&2
      return 1
    fi
    provider=$(fm_worker_account_pi_provider "$model") || {
      echo "error: config/pi-account pins Pi workers to providers ($providers), so a Pi launch needs --model <provider>/<id> naming one of them; '${model:-none}' names no provider, and Firstmate does not guess one" >&2
      return 1
    }
    case " $providers " in
    *" $provider "*) ;;
    *)
      echo "error: config/pi-account pins Pi workers to providers ($providers), but --model '$model' names provider '$provider'" >&2
      return 1
      ;;
    esac
    ;;
  esac
  fm_worker_account_check "$harness" "$declared" "$root" "$executable" "$provider" || return 1
  printf '%s\t%s\t%s\n' "$declared" "$root" "$provider"
}

# fm_worker_account_claude_shed
# Prints the `env` launch prefix that unsets the environment credentials Claude
# ranks above a pinned root's stored login. The caller appends the root
# assignment, or -u CLAUDE_CONFIG_DIR for the ordinary account.
fm_worker_account_claude_shed() {
  local var prefix=env
  for var in $FM_WORKER_ACCOUNT_CLAUDE_SHED; do
    prefix="$prefix -u $var"
  done
  printf '%s\n' "$prefix"
}
