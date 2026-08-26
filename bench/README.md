# Tak Benchmark / Profiling Demo

This directory contains scripts to reproduce the "tak.create feels slow" report on a realistic Phoenix project.

## 1. Profiling `tak.create`

`mix tak.create` now has gated profiling:

```bash
# Flag (recommended for one-off)
mix tak.create feature/foo --profile --no-db

# Env var (useful for scripts / CI)
TAK_PROFILE=1 mix tak.create feature/foo --no-db

# Both print a breakdown like:
# [TAK PROFILE] breakdown (total 2057ms):
#   resolve_name                0ms  (0.0%)
#   branch_exists?             13ms  (0.6%)
#   port_check                  4ms  (0.2%)
#   git worktree add           45ms  (2.2%)
#   copy_env                    4ms  (0.2%)
#   write_dev_local            14ms  (0.7%)
#   mise_config                11ms  (0.5%)
#   deps.get                 1961ms  (95.3%)
#   metadata_write              5ms  (0.2%)
```

When neither `--profile` nor `TAK_PROFILE=1` is set, there is **zero overhead** (no timing calls).

Implementation: `lib/tak/profiling.ex:1`, `lib/tak/worktrees.ex:37`, `lib/mix/tasks/tak.create.ex:41`.

## 2. Generating a realistic Phoenix demo

`bench/generate_demo.exs` creates a `mix phx.new` project plus ~17 large LiveViews (each ~245 lines, 40 `handle_event` clauses) and 6 Ecto schemas/migrations so `mix deps.get` + `mix ecto.setup` have something to do while staying "relatively small".

```bash
# Generates /tmp/tak_phoenix_bench (or custom dest)
mix run bench/generate_demo.exs

# Custom destination
mix run bench/generate_demo.exs /tmp/my_demo

# Result: a normal Phoenix project with :tak wired as a path dep,
# so you can run `mix tak.create` inside it without publishing.
```

This mirrors the user's scenario: "relatively small Phoenix project" that still feels slow.

## 3. Running the profile demo

```bash
# 1. Generate once (requires `phx_new` archive: `mix archive.install hex phx_new`)
mix run bench/generate_demo.exs /tmp/tak_phoenix_bench_demo

# 2. Run profiled creates inside the demo (warm + cold cache, --no-db vs --db)
mix run bench/profile_demo.exs /tmp/tak_phoenix_bench_demo

# Skips DB variant (no Postgres required)
DO_PROFILE_DB=0 mix run bench/profile_demo.exs

# Hyperfine for stable wall-clock (optional):
hyperfine --warmup 1 \
  'TAK_PROFILE=1 mix tak.create feature/x armstrong --no-db' \
  --prepare 'mix tak.remove armstrong --force --yes 2>/dev/null; git branch -D feature/x 2>/dev/null; true'
```

`bench/profile_demo.exs` handles wiring `:tak`, cleaning `trees/*`, and pruning worktrees between runs.

## 4. Interpreting results

On the tak repo itself (tiny project, no LiveViews):

```
deps.get  ~95%  (1.3-2.1s)
git worktree add ~2-4% (40-80ms)
mise_config ~0.5%
everything else <1%
```

Hypothesis for Phoenix demo: `deps.get` and `ecto.setup` will dominate even more due to compilation of large LiveViews and migration runs. The breakdown makes it obvious whether to optimize:

- `deps.get` heavy → consider symlinking `deps`/`_build`, or `mix deps.get --check-locked`, or skipping when lock unchanged.
- `ecto.setup` heavy → consider splitting `ecto.create`/`migrate`, skipping seeds, or async.
- `git worktree add` heavy → check git hooks/LFS.
- `mise_config` heavy → make `mise trust` async/best-effort.

## 5. Test coverage

`test/support/phoenix_demo_generator.ex` + `test/tak/profiling_test.exs` give a fast, offline simulation of the large-LiveView case (15 LiveViews, 80 spans each, 30 events) without needing `phx.new` or network. Run with:

```bash
mix test test/tak/profiling_test.exs --trace
```
