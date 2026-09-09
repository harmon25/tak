#!/usr/bin/env bash
set -euo pipefail

# Compare 3 approaches for tak.create with profiling
# Usage: ./bench/compare_three.sh

ROOT="/home/doug/projects/tak"
LARGE="/tmp/tak_large_demo"
ITER=3

echo "# Comparison: original vs copy_deps vs copy_build"
echo ""
echo "Date: $(date -u)"
echo "Tak: $(git -C $ROOT rev-parse --short HEAD) $(git -C $ROOT branch --show-current)"
echo "Elixir: $(elixir -v 2>&1 | head -n1)"
echo "Mise: $(mise --version 2>&1 | head -n1 || echo 'mise not found')"
echo "Large demo: deps $(du -sh $LARGE/deps 2>&1 | cut -f1) _build $(du -sh $LARGE/_build 2>&1 | cut -f1) at $LARGE"
echo ""

run_small() {
  local label="$1"
  shift
  local flags="$*"
  echo "## Small (tak, $label) $flags"
  for i in $(seq 1 $ITER); do
    rm -rf "$ROOT/trees" 2>/dev/null || true
    git -C "$ROOT" worktree prune >/dev/null 2>&1 || true
    for b in bench/orig bench/deps bench/build bench/test bench/copy-small; do git -C "$ROOT" branch -D "$b" >/dev/null 2>&1 || true; done
    # also remove any bench/* branches
    git -C "$ROOT" branch 2>&1 | grep bench/ | xargs -r -n1 git -C "$ROOT" branch -D >/dev/null 2>&1 || true
    out=$(TAK_PROFILE=1 mix tak.create bench/test-armstrong armstrong --no-db $flags 2>&1)
    total=$(echo "$out" | grep -oP 'total\s+\K\d+ms' | tail -n1 || echo "?")
    copy_deps=$(echo "$out" | grep "copy_deps" | grep -oP '\d+ms' | head -n1 || echo "0ms")
    copy_build=$(echo "$out" | grep "copy_build" | grep -oP '\d+ms' | head -n1 || echo "0ms")
    deps_get=$(echo "$out" | grep "deps.get" | grep -oP '\d+ms' | head -n1 || echo "0ms")
    git_wt=$(echo "$out" | grep "git worktree" | grep -oP '\d+ms' | head -n1 || echo "0ms")
    echo "  Run $i: total $total | copy_deps $copy_deps | copy_build $copy_build | deps.get $deps_get | git $git_wt"
    # cleanup
    mix tak.remove armstrong --force --yes >/dev/null 2>&1 || true
    git -C "$ROOT" branch -D bench/test-armstrong >/dev/null 2>&1 || true
    rm -rf "$ROOT/trees" 2>/dev/null || true
  done
  echo ""
}

run_large() {
  local label="$1"
  shift
  local flags="$*"
  echo "## Large (phoenix demo, $label) $flags"
  for i in $(seq 1 $ITER); do
    rm -rf "$LARGE/trees" 2>/dev/null || true
    git -C "$LARGE" worktree prune >/dev/null 2>&1 || true
    git -C "$LARGE" branch 2>&1 | grep bench/ | xargs -r -n1 git -C "$LARGE" branch -D >/dev/null 2>&1 || true
    out=$(TAK_PROFILE=1 mix tak.create bench/test-armstrong armstrong --no-db $flags 2>&1)
    total=$(echo "$out" | grep -oP 'total\s+\K\d+ms' | tail -n1 || echo "?")
    copy_deps=$(echo "$out" | grep "copy_deps" | grep -oP '\d+ms' | head -n1 || echo "0ms")
    copy_build=$(echo "$out" | grep "copy_build" | grep -oP '\d+ms' | head -n1 || echo "0ms")
    deps_get=$(echo "$out" | grep "deps.get" | grep -oP '\d+ms' | head -n1 || echo "0ms")
    git_wt=$(echo "$out" | grep "git worktree" | grep -oP '\d+ms' | head -n1 || echo "0ms")
    echo "  Run $i: total $total | copy_deps $copy_deps | copy_build $copy_build | deps.get $deps_get | git $git_wt"
    mix tak.remove armstrong --force --yes >/dev/null 2>&1 || true
    git -C "$LARGE" branch -D bench/test-armstrong >/dev/null 2>&1 || true
    rm -rf "$LARGE/trees" 2>/dev/null || true
  done
  echo ""
}

# Ensure parent builds are warm
echo "Warming parent builds..."
mix compile >/dev/null 2>&1 || true
mix deps.get >/dev/null 2>&1 || true
(cd "$LARGE" && mix compile >/dev/null 2>&1 || true)
echo "Warm done"
echo ""

# Small
cd "$ROOT"
run_small "original (no copy)" "--no-copy-deps --no-copy-build"
run_small "copy_deps (default)" "--copy-deps --no-copy-build"
run_small "default (no flags)" ""
run_small "copy_build opt-in" "--copy-deps --copy-build"

# Large
cd "$LARGE"
run_large "original (no copy)" "--no-copy-deps --no-copy-build"
run_large "copy_deps (default)" "--copy-deps --no-copy-build"
run_large "default (no flags)" ""
run_large "copy_build opt-in" "--copy-deps --copy-build"

# Also test first compile after copy_build vs original
echo "## Large: first mix compile after worktree creation (cold _build benefit)"
for flags in "--no-copy-deps --no-copy-build" "--copy-deps --no-copy-build" "--copy-deps --copy-build"; do
  label="$flags"
  rm -rf "$LARGE/trees" 2>/dev/null || true
  git -C "$LARGE" worktree prune >/dev/null 2>&1 || true
  git -C "$LARGE" branch 2>&1 | grep bench/ | xargs -r -n1 git -C "$LARGE" branch -D >/dev/null 2>&1 || true
  TAK_PROFILE=1 mix tak.create bench/compile-test armstrong --no-db $flags >/dev/null 2>&1
  # measure first compile inside worktree
  compile_time=$( (time mix compile 2>&1) 2>&1 | grep real | head -n1 || echo "compile ?")
  # alternative with explicit timing via date
  start=$(date +%s%3N)
  mix compile >/dev/null 2>&1 || true
  end=$(date +%s%3N)
  echo "  $label: first compile ~$((end-start))ms (after worktree) + $compile_time"
  mix tak.remove armstrong --force --yes >/dev/null 2>&1 || true
  git -C "$LARGE" branch -D bench/compile-test >/dev/null 2>&1 || true
done
