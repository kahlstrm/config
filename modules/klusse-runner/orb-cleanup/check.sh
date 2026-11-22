# Prints the git facts of every checkout under a home directory, for orb-cleanup. Run as
# `sh -s -- HOME MODE CACHE...`. One tab-separated line per checkout:
#   repo  PATH BRANCH HEAD UNPUSHED CHANGED UNTRACKED IGNORED STASHES
# where UNPUSHED counts commits of HEAD, the local branches and tags that no remote branch
# has, and CHANGED, UNTRACKED and IGNORED count `git status` entries outside node_modules; or
#   doubt PATH REASON
# when a checkout cannot be read. The last line is `done`, so a cut-off run shows.
#
# MODE `copy` means HOME is a copy of a stopped orb's home: a `.git` file there points at
# paths the copy lacks, so such checkouts are doubts. Otherwise HOME is the orb's own, and
# linked worktrees outside it are checked too. node_modules and the CACHE directories under
# HOME are not searched: tools keep checkouts there that are no one's work.
set -u
home=$1
mode=$2
shift 2

# No optional locks: in a running orb, status must not rewrite the index as another user.
g() { git --no-optional-locks -c safe.directory='*' -c core.fsmonitor=false "$@"; }
doubt() { printf 'doubt\t%s\t%s\n' "$1" "$2"; }

check() {
  dir=$1
  if ! head=$(g -C "$dir" rev-parse --verify -q HEAD); then
    doubt "$dir" "cannot read HEAD"
    return
  fi
  branch=$(g -C "$dir" symbolic-ref --short -q HEAD) || branch="(detached)"
  if ! unpushed=$(g -C "$dir" rev-list --count HEAD --branches --tags --not --remotes); then
    doubt "$dir" "cannot compare with the remotes"
    return
  fi
  if ! status=$(g -C "$dir" status --porcelain=v1 --ignored); then
    doubt "$dir" "git status failed"
    return
  fi
  status=$(printf '%s\n' "$status" | grep -Ev '^.. (.*/)?node_modules(/|$)')
  changed=$(printf '%s\n' "$status" | grep -cv -e '^??' -e '^!!' -e '^$')
  untracked=$(printf '%s\n' "$status" | grep -c '^??')
  ignored=$(printf '%s\n' "$status" | grep -c '^!!')
  stashes=0
  if g -C "$dir" rev-parse -q --verify refs/stash > /dev/null; then
    if ! stashes=$(g -C "$dir" rev-list --walk-reflogs --count refs/stash); then
      doubt "$dir" "cannot count stashes"
      return
    fi
  fi
  printf 'repo\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$dir" "$branch" "$head" \
    "$unpushed" "$changed" "$untracked" "$ignored" "$stashes"
}

count=$#
for cache do
  set -- "$@" -o -path "$home/$cache"
done
shift "$count"
if ! found=$(find "$home" \( -name node_modules "$@" \) -prune -o -name .git -print); then
  doubt "$home" "cannot search the home directory"
fi

printf '%s\n' "$found" | while IFS= read -r git; do
  [ -n "$git" ] || continue
  dir=${git%/.git}
  if [ "$mode" = copy ]; then
    if [ ! -d "$git" ]; then
      doubt "$dir" "linked checkout, unreadable in a copy"
      continue
    fi
    if [ -n "$(ls -A "$git/worktrees" 2> /dev/null)" ]; then
      doubt "$dir" "has linked worktrees, unreadable in a copy"
      continue
    fi
  fi
  check "$dir"
  if [ "$mode" != copy ] && [ -d "$git" ]; then
    g -C "$dir" worktree list --porcelain | sed -n 's/^worktree //p' | while IFS= read -r tree; do
      case $tree in
        "$home"/*) ;;
        *) check "$tree" ;;
      esac
    done
  fi
done
echo done
