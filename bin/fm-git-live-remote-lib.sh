#!/usr/bin/env bash
# Shared live-remote proof for safety decisions that would otherwise trust stale
# refs/remotes/* state. Every positive verdict begins with git ls-remote against
# the configured remote. Advertised branch refs whose tip objects are absent
# locally are fetched together before checking ancestry.
#
# Public functions:
#   fm_git_live_remote_heads <repo>
#     Print the commit IDs advertised by every configured remote branch after
#     fetching any advertised tip object that is not present locally.
#   fm_git_commit_is_in_live_remote_heads <repo> <commit> <heads>
#     True when commit is contained by a captured live-remote head set.
#   fm_git_commit_is_on_live_remote <repo> <commit>
#     True when the commit is contained by any branch currently advertised by
#     any configured remote.

if ! command -v fm_run_timed >/dev/null 2>&1; then
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"
fi

FM_GIT_LIVE_REMOTE_NOT_FOUND=1
FM_GIT_LIVE_REMOTE_TIMEOUT=2
FM_GIT_LIVE_REMOTE_BUDGET_EXHAUSTED=3
FM_GIT_LIVE_REMOTE_PROBE_FAILED=4

fm_git_live_remote_run() {  # <deadline> <operation-timeout> <git-args...>
  local deadline=$1 operation_timeout=$2 remaining bound budget_limited=0 rc=0
  shift 2
  remaining=$((deadline - SECONDS))
  [ "$remaining" -gt 0 ] || return "$FM_GIT_LIVE_REMOTE_BUDGET_EXHAUSTED"
  bound=$operation_timeout
  if [ "$remaining" -lt "$bound" ]; then
    bound=$remaining
    budget_limited=1
  fi
  fm_run_timed "$bound" env \
    GIT_TERMINAL_PROMPT=0 \
    GCM_INTERACTIVE=Never \
    GIT_ASKPASS=false \
    SSH_ASKPASS=false \
    SSH_ASKPASS_REQUIRE=never \
    GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh} -o BatchMode=yes" \
    git "$@" </dev/null || rc=$?
  if [ "$rc" -eq 124 ]; then
    [ "$budget_limited" -eq 0 ] || return "$FM_GIT_LIVE_REMOTE_BUDGET_EXHAUSTED"
    return "$FM_GIT_LIVE_REMOTE_TIMEOUT"
  fi
  [ "$rc" -eq 0 ] || return "$FM_GIT_LIVE_REMOTE_PROBE_FAILED"
}

fm_git_live_remote_heads() {  # <repo>
  local repo=$1 remote heads line remote_head remote_ref rc status=0
  local operation_timeout=${FM_GIT_LIVE_REMOTE_OPERATION_TIMEOUT_SECS:-15}
  local budget=${FM_GIT_LIVE_REMOTE_BUDGET_SECS:-45} deadline
  local -a missing_refs
  case "$operation_timeout:$budget" in
    *[!0-9:]*|0:*|*:0) return "$FM_GIT_LIVE_REMOTE_PROBE_FAILED" ;;
  esac
  deadline=$((SECONDS + budget))
  while IFS= read -r remote; do
    [ -n "$remote" ] || continue
    if heads=$(fm_git_live_remote_run "$deadline" "$operation_timeout" \
      -C "$repo" ls-remote --heads "$remote" 2>/dev/null); then
      :
    else
      rc=$?
      case "$rc" in
        "$FM_GIT_LIVE_REMOTE_BUDGET_EXHAUSTED") status=$rc; break ;;
        "$FM_GIT_LIVE_REMOTE_TIMEOUT") status=$rc ;;
        *) [ "$status" -ne 0 ] || status=$FM_GIT_LIVE_REMOTE_PROBE_FAILED ;;
      esac
      continue
    fi
    missing_refs=()
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      remote_head=${line%%$'\t'*}
      remote_ref=${line#*$'\t'}
      [ -n "$remote_head" ] && [ "$remote_ref" != "$line" ] || continue
      if ! git -C "$repo" cat-file -e "$remote_head^{commit}" 2>/dev/null; then
        missing_refs+=("$remote_ref")
      fi
    done <<EOF
$heads
EOF
    if [ "${#missing_refs[@]}" -gt 0 ]; then
      if fm_git_live_remote_run "$deadline" "$operation_timeout" \
        -C "$repo" fetch --quiet --no-tags "$remote" "${missing_refs[@]}" >/dev/null 2>&1; then
        :
      else
        rc=$?
        case "$rc" in
          "$FM_GIT_LIVE_REMOTE_BUDGET_EXHAUSTED") status=$rc ;;
          "$FM_GIT_LIVE_REMOTE_TIMEOUT") [ "$status" -eq "$FM_GIT_LIVE_REMOTE_BUDGET_EXHAUSTED" ] || status=$rc ;;
          *) [ "$status" -ne 0 ] || status=$FM_GIT_LIVE_REMOTE_PROBE_FAILED ;;
        esac
      fi
    fi
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      remote_head=${line%%$'\t'*}
      remote_ref=${line#*$'\t'}
      [ -n "$remote_head" ] && [ "$remote_ref" != "$line" ] || continue
      printf '%s\n' "$remote_head"
    done <<EOF
$heads
EOF
    [ "$status" -ne "$FM_GIT_LIVE_REMOTE_BUDGET_EXHAUSTED" ] || break
  done < <(git -C "$repo" remote 2>/dev/null)
  return "$status"
}

fm_git_commit_is_in_live_remote_heads() {  # <repo> <commit> <heads>
  local repo=$1 commit=$2 heads=$3 remote_head
  while IFS= read -r remote_head; do
    [ -n "$remote_head" ] || continue
    if [ "$commit" = "$remote_head" ] \
      || { git -C "$repo" cat-file -e "$remote_head^{commit}" 2>/dev/null \
        && git -C "$repo" merge-base --is-ancestor "$commit" "$remote_head" 2>/dev/null; }; then
      return 0
    fi
  done <<EOF
$heads
EOF
  return 1
}

fm_git_commit_is_on_live_remote() {  # <repo> <commit>
  local repo=$1 commit=$2 heads snapshot_rc=0
  if heads=$(fm_git_live_remote_heads "$repo"); then
    :
  else
    snapshot_rc=$?
  fi
  fm_git_commit_is_in_live_remote_heads "$repo" "$commit" "$heads" && return 0
  [ "$snapshot_rc" -eq 0 ] || return "$snapshot_rc"
  return "$FM_GIT_LIVE_REMOTE_NOT_FOUND"
}
