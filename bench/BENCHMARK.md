# Benchmark: tak.create — deps.get dominates → copy_deps (default) vs copy_build (opt-in)

Recorded 2026-08-25 (initial) + 2026-09-04 (copy_deps) + 2026-09-04 (copy_build opt-in). Upstream: https://github.com/bytebottom/tak/issues/1 / https://github.com/harmon25/tak/issues/1

## Summary

`TAK_PROFILE=1` / `--profile` harness showed `mix deps.get` was wall time. Implemented **copy `deps/` from parent (default, `File.cp_r`)** when `mix.lock` in sync, and **opt-in copy `_build/` with text rewrite** (`--copy-build`, `config :tak, copy_build: false`, `lib/tak/worktrees.ex:maybe_copy_build` + `rewrite_build_paths`). Three-way comparison `--no-copy-*` vs default vs `--copy-build`.

Results ( `--no-db`, `TAK_PROFILE=1` ):

| project | original (no copy) | copy_deps (default) | copy_deps+copy_build (opt-in) |
|---|---|---|---|
| small `tak` (5.9M `_build`, 6 deps) | 1029ms (deps 967ms 94%, git 40ms) / 1110ms | **123ms** (copy 63ms, git 39ms) / 101-146ms | **172ms** (copy_deps 56ms + copy_build 60ms) / 214ms — 5-6× vs orig, but 1.4× slower than deps-only (small overhead not worth it) |
| large demo 17 LiveViews 4165 LOC (deps 92M, _build 16M) | 7176ms (deps 7132ms 99.4%, git 26ms) / 6549ms | **846ms** (copy 803ms, git 24ms) / 509-586ms | **868ms** (copy_deps 576ms + copy_build 253ms, git 24ms) / 509ms — ~8-12× vs orig, ~equal to deps-only (extra 22ms for build) |

Default `copy_deps` gives **6-10× small / 11-13× large** vs original (976ms→101ms, 6.5s→509ms earlier). `copy_build` adds ~60ms small / ~253ms large and keeps `deps.get 0ms`; subsequent `mix compile` inside worktree after copy_build is ~200ms vs 3s cold (not shown in `tak.create` total but beneficial for `--db` + `phx.server` first boot).

## Environment

- tak `perf/copy-deps` @ `95f8bbd` + profiling + copy_deps
- Elixir 1.20.2 / OTP 28 / Linux WSL2 6.18.33.2 (4c)
- phx_new 1.8.12, mise present
- --no-db (Postgres not involved)
- `copy_deps` default `true` via `config :tak, copy_deps: false` or `--copy-deps/--no-copy-deps`

## Small project (tak itself) — before/after

Before ( `perf/profiling+fix` , no copy):
```
Run1: total 3220ms  deps.get 3100ms (96.3%)  git 59ms  mise 15ms  real 4.7s
Run2: total 2831ms  deps.get 2629ms (92.9%)
```

After ( `perf/copy-deps` ):
```
Default (copy): total 101ms  copy_deps 48ms (47.5%)  deps.get 0ms (skipped)  git 35ms  mise 6ms
Default repeat: total 138ms  copy_deps 85ms (61.6%)  git 35ms
--no-copy-deps: total 976ms  copy 0ms  deps.get 922ms (94.5%)  git 35ms
--no-copy-deps repeat: total 900ms  deps.get 841ms (93.4%)
```

## Large Phoenix demo (17 LiveViews, 4165 LOC, 6 schemas, deps 92M)

Before:
```
cold mix deps.get in demo root: 30.0s (warm 2.17s)
Run1: total 20424ms  deps.get 20313ms (99.5%)
Run2: total 23127ms  deps.get 23015ms (99.5%)
```

After:
```
deps 92M
Default: total 509ms  copy_deps 469ms (92.1%)  deps.get 0ms  git 23ms  mise 7ms
Default repeat: total 586ms  copy 546ms (93.2%)  deps 0ms
--copy-deps explicit: total 522ms  copy 483ms
--no-copy-deps: total 6549ms  deps.get 6511ms (99.4%) / 6846ms  deps 6809ms
```

Demo generated via `bench/generate_demo.exs` (wired :tak path, committed `mix.lock`). Large is ~6-7x small before, now both sub-second with copy. `git worktree add` 23-58ms, `mise` 6-15ms are now the long poles.

## Interpretation

- Before: cold `_build` per worktree → `mix deps.get` recompiles deps + app (20s large, 3s small)
- After: `File.cp_r("deps", "trees/<name>/deps")` ~48-85ms small, ~469-610ms large (92M) + skip `deps.get` when `mix.lock` identical → total 100-586ms
- Fallback: if `deps/` missing or `mix.lock` mismatch, runs `deps.get` normally; `mix.lock` also copied if untracked (synthetic demo)
- Also copies `mix.lock` if worktree missing it, so synthetic demo works without committed lock

## Next

- `--db` variant (ecto.setup) still needs profiling; copy_build shows that `_build` copy saves first `mix compile` (~200ms vs 3s) but `tak.create --no-db` already benefits most from `copy_deps`
- Copy_build rewrites only text artefacts (`.app`, `.mix/*`, `compile.*`, `consolidated/*`), skips `.beam` `debug_info` (contains absolute `file`), and `File.touch` resets mtimes to avoid future warning; fallback to compile if rewrite fails
- Consider `cp --reflink=auto` for faster COW on supported FS

See also `bench/README.md`, `bench/profile_demo.exs`, `lib/tak/profiling.ex`, `lib/tak/worktrees.ex:maybe_copy_*`.

