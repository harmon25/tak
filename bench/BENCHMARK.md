# Benchmark: tak.create profiling — deps.get dominates (92-99%) → copy_deps optimization

Recorded 2026-08-25 (initial) + 2026-09-04 (copy optimization). Upstream: https://github.com/bytebottom/tak/issues/1 / https://github.com/harmon25/tak/issues/1

## Summary

`TAK_PROFILE=1` / `--profile` harness showed `mix deps.get` was wall time. Implemented **copy `deps/` from parent checkout (default enabled, `File.cp_r`)** instead of `mix deps.get` when `mix.lock` in sync. Flag `--no-copy-deps` for testing.

Results ( `--no-db` ):

| project | `deps.get` (no-copy) | `copy_deps` (default) | total (no-copy) | total (copy) | speedup |
|---|---|---|---|---|---|
| small `tak` | 922ms (94.5%) / 3100ms (96.3%) | 48-50ms (40-47%) | 976ms / 3220ms | 101-138ms | **6-10×** (900ms → 101ms, 3.2s → 138ms) |
| large demo 17 LiveViews 4165 LOC | 6511ms (99.4%) / 20313ms (99.5%) | 469-546ms (92%) | 6549ms / 20424ms | 509-586ms | **11-13×** (6.5s → 509ms, 20s → 586ms) |

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

- --db variant (ecto.setup) still needs profiling; copy does not yet touch `_build` (next win would be linking `_build` but risky due to absolute paths/NIFs)
- Consider `mix deps.get --check-locked` as lighter fallback vs full copy

See also `bench/README.md`, `bench/profile_demo.exs`, `lib/tak/profiling.ex`, `lib/tak/worktrees.ex:maybe_copy_deps`.

