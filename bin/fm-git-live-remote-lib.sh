#!/usr/bin/env bash
# Shared live-remote proof for safety decisions that would otherwise trust stale
# refs/remotes/* state. Every positive verdict begins with git ls-remote against
# the configured remote. Advertised branch refs whose tip objects are absent
# locally are fetched together before checking ancestry.
#
# Public functions:
#   fm_git_live_remote_deadline
#     Print one absolute deadline from the configured overall probe budget.
#   fm_git_live_remote_heads <repo> [deadline]
#     Print the commit IDs advertised by every configured remote branch after
#     fetching any advertised tip object that is not present locally.
#   fm_git_commit_is_in_live_remote_heads <repo> <commit> <heads> [deadline]
#     True when commit is contained by a captured live-remote head set.
#   fm_git_commit_is_on_live_remote <repo> <commit> [deadline]
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
FM_GIT_LIVE_REMOTE_RAW_BUDGET_EXHAUSTED=125

fm_git_live_remote_deadline() {
  local budget=${FM_GIT_LIVE_REMOTE_BUDGET_SECS:-45}
  case "$budget" in
    ''|*[!0-9]*|0) return "$FM_GIT_LIVE_REMOTE_PROBE_FAILED" ;;
  esac
  printf '%s\n' "$((SECONDS + budget))"
}

fm_git_live_remote_operation_timeout() {
  local operation_timeout=${FM_GIT_LIVE_REMOTE_OPERATION_TIMEOUT_SECS:-15}
  case "$operation_timeout" in
    ''|*[!0-9]*|0) return "$FM_GIT_LIVE_REMOTE_PROBE_FAILED" ;;
  esac
  printf '%s\n' "$operation_timeout"
}

fm_git_live_remote_run_raw() {  # <deadline> <operation-timeout> <git-args...>
  local deadline=$1 operation_timeout=$2 remaining bound budget_limited=0 rc=0
  shift 2
  remaining=$((deadline - SECONDS))
  [ "$remaining" -gt 0 ] || return "$FM_GIT_LIVE_REMOTE_RAW_BUDGET_EXHAUSTED"
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
    [ "$budget_limited" -eq 0 ] || return "$FM_GIT_LIVE_REMOTE_RAW_BUDGET_EXHAUSTED"
  fi
  return "$rc"
}

fm_git_live_remote_run() {  # <deadline> <operation-timeout> <git-args...>
  local rc=0
  fm_git_live_remote_run_raw "$@" || rc=$?
  case "$rc" in
    0) return 0 ;;
    124) return "$FM_GIT_LIVE_REMOTE_TIMEOUT" ;;
    "$FM_GIT_LIVE_REMOTE_RAW_BUDGET_EXHAUSTED") return "$FM_GIT_LIVE_REMOTE_BUDGET_EXHAUSTED" ;;
    *) return "$FM_GIT_LIVE_REMOTE_PROBE_FAILED" ;;
  esac
}

fm_git_live_remote_note_status() {  # <current> <new>
  local current=$1 new=$2
  case "$new:$current" in
    "$FM_GIT_LIVE_REMOTE_BUDGET_EXHAUSTED":*) printf '%s\n' "$new" ;;
    "$FM_GIT_LIVE_REMOTE_TIMEOUT":"$FM_GIT_LIVE_REMOTE_BUDGET_EXHAUSTED") printf '%s\n' "$current" ;;
    "$FM_GIT_LIVE_REMOTE_TIMEOUT":*) printf '%s\n' "$new" ;;
    "$FM_GIT_LIVE_REMOTE_PROBE_FAILED":0) printf '%s\n' "$new" ;;
    *) printf '%s\n' "$current" ;;
  esac
}

fm_git_live_remote_url_is_self_referential() {  # <repo-real> <git-dir-real> <common-dir-real> <url>
  local repo_real=$1 git_dir_real=$2 common_dir_real=$3 url=$4 path real
  case "$url" in
    file://*) path=${url#file://} ;;
    *://*|*:*|'') return 1 ;;
    /*) path=$url ;;
    *) path="$repo_real/$url" ;;
  esac
  real=$(CDPATH='' cd -- "$path" 2>/dev/null && pwd -P) || return 1
  [ "$real" = "$repo_real" ] || [ "$real" = "$git_dir_real" ] || [ "$real" = "$common_dir_real" ]
}

fm_git_live_remote_heads() {  # <repo> [deadline]
  local repo=$1 deadline=${2:-} operation_timeout remotes remote remote_url heads line
  local remote_head remote_ref rc status=0 repo_real git_dir common_dir scan_exhausted=0
  local -a missing_refs
  operation_timeout=$(fm_git_live_remote_operation_timeout) || return "$FM_GIT_LIVE_REMOTE_PROBE_FAILED"
  [ -n "$deadline" ] || deadline=$(fm_git_live_remote_deadline) \
    || return "$FM_GIT_LIVE_REMOTE_PROBE_FAILED"
  case "$deadline" in ''|*[!0-9]*) return "$FM_GIT_LIVE_REMOTE_PROBE_FAILED" ;; esac
  [ "$SECONDS" -lt "$deadline" ] || return "$FM_GIT_LIVE_REMOTE_BUDGET_EXHAUSTED"
  repo_real=$(CDPATH='' cd -- "$repo" 2>/dev/null && pwd -P) \
    || return "$FM_GIT_LIVE_REMOTE_PROBE_FAILED"
  git_dir=$(fm_git_live_remote_run_raw "$deadline" "$operation_timeout" \
    -C "$repo" rev-parse --absolute-git-dir 2>/dev/null) || rc=$?
  case "${rc:-0}" in
    0) ;;
    124) return "$FM_GIT_LIVE_REMOTE_TIMEOUT" ;;
    "$FM_GIT_LIVE_REMOTE_RAW_BUDGET_EXHAUSTED") return "$FM_GIT_LIVE_REMOTE_BUDGET_EXHAUSTED" ;;
    *) return "$FM_GIT_LIVE_REMOTE_PROBE_FAILED" ;;
  esac
  git_dir=$(CDPATH='' cd -- "$git_dir" 2>/dev/null && pwd -P) \
    || return "$FM_GIT_LIVE_REMOTE_PROBE_FAILED"
  rc=0
  common_dir=$(fm_git_live_remote_run_raw "$deadline" "$operation_timeout" \
    -C "$repo" rev-parse --git-common-dir 2>/dev/null) || rc=$?
  case "$rc" in
    0) ;;
    124) return "$FM_GIT_LIVE_REMOTE_TIMEOUT" ;;
    "$FM_GIT_LIVE_REMOTE_RAW_BUDGET_EXHAUSTED") return "$FM_GIT_LIVE_REMOTE_BUDGET_EXHAUSTED" ;;
    *) return "$FM_GIT_LIVE_REMOTE_PROBE_FAILED" ;;
  esac
  case "$common_dir" in /*) ;; *) common_dir="$repo_real/$common_dir" ;; esac
  common_dir=$(CDPATH='' cd -- "$common_dir" 2>/dev/null && pwd -P) \
    || return "$FM_GIT_LIVE_REMOTE_PROBE_FAILED"
  rc=0
  remotes=$(fm_git_live_remote_run_raw "$deadline" "$operation_timeout" \
    -C "$repo" remote 2>/dev/null) || rc=$?
  case "$rc" in
    0) ;;
    124) return "$FM_GIT_LIVE_REMOTE_TIMEOUT" ;;
    "$FM_GIT_LIVE_REMOTE_RAW_BUDGET_EXHAUSTED") return "$FM_GIT_LIVE_REMOTE_BUDGET_EXHAUSTED" ;;
    *) return "$FM_GIT_LIVE_REMOTE_PROBE_FAILED" ;;
  esac
  while IFS= read -r remote; do
    [ -n "$remote" ] || continue
    rc=0
    remote_url=$(fm_git_live_remote_run_raw "$deadline" "$operation_timeout" \
      -C "$repo" remote get-url "$remote" 2>/dev/null) || rc=$?
    case "$rc" in
      0) ;;
      124) status=$(fm_git_live_remote_note_status "$status" "$FM_GIT_LIVE_REMOTE_TIMEOUT"); continue ;;
      "$FM_GIT_LIVE_REMOTE_RAW_BUDGET_EXHAUSTED") status=$FM_GIT_LIVE_REMOTE_BUDGET_EXHAUSTED; break ;;
      *) status=$(fm_git_live_remote_note_status "$status" "$FM_GIT_LIVE_REMOTE_PROBE_FAILED"); continue ;;
    esac
    if fm_git_live_remote_url_is_self_referential \
      "$repo_real" "$git_dir" "$common_dir" "$remote_url"; then
      status=$(fm_git_live_remote_note_status "$status" "$FM_GIT_LIVE_REMOTE_PROBE_FAILED")
      continue
    fi
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
      rc=0
      fm_git_live_remote_run_raw "$deadline" "$operation_timeout" \
        -C "$repo" cat-file -e "$remote_head^{commit}" >/dev/null 2>&1 || rc=$?
      case "$rc" in
        0) ;;
        124)
          status=$(fm_git_live_remote_note_status "$status" "$FM_GIT_LIVE_REMOTE_TIMEOUT")
          missing_refs+=("$remote_ref")
          ;;
        "$FM_GIT_LIVE_REMOTE_RAW_BUDGET_EXHAUSTED")
          status=$FM_GIT_LIVE_REMOTE_BUDGET_EXHAUSTED
          scan_exhausted=1
          break
          ;;
        *) missing_refs+=("$remote_ref") ;;
      esac
    done <<EOF
$heads
EOF
    if [ "$scan_exhausted" -eq 0 ] && [ "${#missing_refs[@]}" -gt 0 ]; then
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
      if [ "$SECONDS" -ge "$deadline" ]; then
        status=$FM_GIT_LIVE_REMOTE_BUDGET_EXHAUSTED
        break
      fi
      remote_head=${line%%$'\t'*}
      remote_ref=${line#*$'\t'}
      [ -n "$remote_head" ] && [ "$remote_ref" != "$line" ] || continue
      printf '%s\n' "$remote_head"
    done <<EOF
$heads
EOF
    [ "$status" -ne "$FM_GIT_LIVE_REMOTE_BUDGET_EXHAUSTED" ] || break
  done <<EOF
$remotes
EOF
  return "$status"
}

fm_git_commit_is_in_live_remote_heads() {  # <repo> <commit> <heads> [deadline]
  local repo=$1 commit=$2 heads=$3 deadline=${4:-} operation_timeout remote_head rc status=0
  operation_timeout=$(fm_git_live_remote_operation_timeout) || return "$FM_GIT_LIVE_REMOTE_PROBE_FAILED"
  [ -n "$deadline" ] || deadline=$(fm_git_live_remote_deadline) \
    || return "$FM_GIT_LIVE_REMOTE_PROBE_FAILED"
  case "$deadline" in ''|*[!0-9]*) return "$FM_GIT_LIVE_REMOTE_PROBE_FAILED" ;; esac
  while IFS= read -r remote_head; do
    [ -n "$remote_head" ] || continue
    [ "$SECONDS" -lt "$deadline" ] || return "$FM_GIT_LIVE_REMOTE_BUDGET_EXHAUSTED"
    [ "$commit" != "$remote_head" ] || return 0
    rc=0
    fm_git_live_remote_run_raw "$deadline" "$operation_timeout" \
      -C "$repo" cat-file -e "$remote_head^{commit}" >/dev/null 2>&1 || rc=$?
    case "$rc" in
      0)
        rc=0
        fm_git_live_remote_run_raw "$deadline" "$operation_timeout" \
          -C "$repo" merge-base --is-ancestor "$commit" "$remote_head" >/dev/null 2>&1 || rc=$?
        case "$rc" in
          0) return 0 ;;
          1) ;;
          124) status=$(fm_git_live_remote_note_status "$status" "$FM_GIT_LIVE_REMOTE_TIMEOUT") ;;
          "$FM_GIT_LIVE_REMOTE_RAW_BUDGET_EXHAUSTED") return "$FM_GIT_LIVE_REMOTE_BUDGET_EXHAUSTED" ;;
          *) status=$(fm_git_live_remote_note_status "$status" "$FM_GIT_LIVE_REMOTE_PROBE_FAILED") ;;
        esac
        ;;
      124) status=$(fm_git_live_remote_note_status "$status" "$FM_GIT_LIVE_REMOTE_TIMEOUT") ;;
      "$FM_GIT_LIVE_REMOTE_RAW_BUDGET_EXHAUSTED") return "$FM_GIT_LIVE_REMOTE_BUDGET_EXHAUSTED" ;;
      *) ;;
    esac
  done <<EOF
$heads
EOF
  [ "$status" -eq 0 ] || return "$status"
  return "$FM_GIT_LIVE_REMOTE_NOT_FOUND"
}

fm_git_commit_is_on_live_remote() {  # <repo> <commit> [deadline]
  local repo=$1 commit=$2 deadline=${3:-} heads snapshot_rc=0 contain_rc=0 status
  [ -n "$deadline" ] || deadline=$(fm_git_live_remote_deadline) \
    || return "$FM_GIT_LIVE_REMOTE_PROBE_FAILED"
  if heads=$(fm_git_live_remote_heads "$repo" "$deadline"); then
    :
  else
    snapshot_rc=$?
  fi
  fm_git_commit_is_in_live_remote_heads "$repo" "$commit" "$heads" "$deadline" || contain_rc=$?
  [ "$contain_rc" -ne 0 ] || return 0
  status=$(fm_git_live_remote_note_status "$snapshot_rc" "$contain_rc")
  [ "$status" -ne 0 ] || status=$FM_GIT_LIVE_REMOTE_NOT_FOUND
  return "$status"
}
