#!/usr/bin/env bash
# Shared live-remote proof for safety decisions that would otherwise trust stale
# refs/remotes/* state. Every positive verdict begins with git ls-remote against
# the configured remote. When an advertised tip object is absent locally, the
# exact live branch ref is fetched into FETCH_HEAD before checking ancestry.
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

fm_git_live_remote_heads() {  # <repo>
  local repo=$1 remote heads line remote_head remote_ref
  while IFS= read -r remote; do
    [ -n "$remote" ] || continue
    heads=$(git -C "$repo" ls-remote --heads "$remote" 2>/dev/null) || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      remote_head=${line%%$'\t'*}
      remote_ref=${line#*$'\t'}
      [ -n "$remote_head" ] && [ "$remote_ref" != "$line" ] || continue
      if ! git -C "$repo" cat-file -e "$remote_head^{commit}" 2>/dev/null; then
        git -C "$repo" fetch --quiet --no-tags "$remote" "$remote_ref" >/dev/null 2>&1 || true
      fi
      printf '%s\n' "$remote_head"
    done <<EOF
$heads
EOF
  done < <(git -C "$repo" remote 2>/dev/null)
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
  local repo=$1 commit=$2 heads
  heads=$(fm_git_live_remote_heads "$repo") || return 1
  fm_git_commit_is_in_live_remote_heads "$repo" "$commit" "$heads"
}
