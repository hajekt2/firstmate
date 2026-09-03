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
