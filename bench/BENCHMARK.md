# Benchmark: tak.create profiling — deps.get dominates (92-99%)

Recorded 2026-08-25. Upstream issue: https://github.com/bytebottom/tak/issues/1

## Summary

`TAK_PROFILE=1` / `--profile` harness shows `mix deps.get` is wall time.

## Environment

- tak `perf/profiling+fix` @ `255fca4` + profiling
- Elixir 1.20.2 / OTP 28 / Linux WSL2 6.18.33.2 (4c)
- phx_new 1.8.12, mise present
- --no-db (Postgres not involved)

## Small project (tak itself)

```
Run1: total 3220ms  deps.get 3100ms (96.3%)  git 59ms (1.8%)  mise 15ms
Run2: total 2831ms  deps.get 2629ms (92.9%)  git 107ms (3.8%)
real ~4.7-4.8s
```

## Large Phoenix demo (17 LiveViews, 4165 LOC, 6 schemas/migrations)

```
cold mix deps.get in demo root: 30.0s  (warm 2.17s)
Run1: total 20424ms  deps.get 20313ms (99.5%)  git 58ms (0.3%)
Run2: total 23127ms  deps.get 23015ms (99.5%)  git 51ms (0.2%)
```

Demo generated via `bench/generate_demo.exs` (wired :tak path, committed, so git worktree works). Large is ~6-7x small.

## Interpretation

- resolve/validate/port/mkdir/copy/write/mise/metadata <30ms combined
- git worktree add 50-110ms, mise 15-27ms → noise
- cold _build per worktree causes recompile; warm demo deps.get is only 2s vs 20s cold

## Next

- symlink/share _build/deps or --check-locked fast path
- benchmark --db variant (ecto.setup) next
- async mise trust (low prio)

See also `bench/README.md`, `bench/profile_demo.exs`.
