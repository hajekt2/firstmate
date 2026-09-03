#!/usr/bin/env bash
# Shared live-remote proof for safety decisions that would otherwise trust stale
# refs/remotes/* state. Every positive verdict begins with git ls-remote against
# the configured remote. When an advertised tip object is absent locally, the
# exact live branch ref is fetched into FETCH_HEAD before checking ancestry.
#
# Public functions:
#   fm_git_commit_is_on_live_remote <repo> <commit>
#     True when the commit is contained by any branch currently advertised by
#     any configured remote.
#   fm_git_live_upstream_contains_commit <repo> <branch> <commit>
#     True when branch has a remote upstream that currently exists and contains
#     commit. A local branch configured as its upstream is not a remote proof.

fm_git_advertised_head_contains_commit() {  # <repo> <remote> <ref> <head> <commit>
  local repo=$1 remote=$2 remote_ref=$3 remote_head=$4 commit=$5
  if [ "$commit" = "$remote_head" ]; then
    return 0
  fi
  if ! git -C "$repo" cat-file -e "$remote_head^{commit}" 2>/dev/null; then
    git -C "$repo" fetch --quiet --no-tags "$remote" "$remote_ref" >/dev/null 2>&1 || return 1
    git -C "$repo" cat-file -e "$remote_head^{commit}" 2>/dev/null || return 1
  fi
  git -C "$repo" merge-base --is-ancestor "$commit" "$remote_head" 2>/dev/null
}

fm_git_commit_is_on_live_remote() {  # <repo> <commit>
  local repo=$1 commit=$2 remote heads line remote_head remote_ref
  while IFS= read -r remote; do
    [ -n "$remote" ] || continue
    heads=$(git -C "$repo" ls-remote --heads "$remote" 2>/dev/null) || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      remote_head=${line%%$'\t'*}
      remote_ref=${line#*$'\t'}
      [ -n "$remote_head" ] && [ "$remote_ref" != "$line" ] || continue
      fm_git_advertised_head_contains_commit \
        "$repo" "$remote" "$remote_ref" "$remote_head" "$commit" && return 0
    done <<EOF
$heads
EOF
  done < <(git -C "$repo" remote 2>/dev/null)
  return 1
}

fm_git_live_upstream_contains_commit() {  # <repo> <branch> <commit>
  local repo=$1 branch=$2 commit=$3 upstream remote merge_ref line remote_head
  [ -n "$branch" ] && [ "$branch" != HEAD ] || return 1
  upstream=$(git -C "$repo" rev-parse --abbrev-ref '@{u}' 2>/dev/null) || return 1
  [ -n "$upstream" ] || return 1
  remote=$(git -C "$repo" config --get "branch.$branch.remote" 2>/dev/null) || return 1
  merge_ref=$(git -C "$repo" config --get "branch.$branch.merge" 2>/dev/null) || return 1
  [ -n "$remote" ] && [ "$remote" != . ] || return 1
  case "$merge_ref" in refs/heads/*) ;; *) return 1 ;; esac
  line=$(git -C "$repo" ls-remote --exit-code --heads "$remote" "$merge_ref" 2>/dev/null) || return 1
  [ "$(printf '%s\n' "$line" | sed '/^$/d' | wc -l | tr -d '[:space:]')" = 1 ] || return 1
  [ "${line#*$'\t'}" = "$merge_ref" ] || return 1
  remote_head=${line%%$'\t'*}
  [ -n "$remote_head" ] && [ "$remote_head" != "$line" ] || return 1
  fm_git_advertised_head_contains_commit \
    "$repo" "$remote" "$merge_ref" "$remote_head" "$commit"
}
