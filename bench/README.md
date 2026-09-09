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
#   copy_deps                  48ms  (47.5%)   # when --copy-deps (default)
#   deps.get                    0ms  (0.0%)   # skipped when copy in sync
#   metadata_write              5ms  (0.2%)
```

When neither `--profile` nor `TAK_PROFILE=1` is set, there is **zero overhead** (no timing calls).

Implementation: `lib/tak/profiling.ex:1`, `lib/tak/worktrees.ex:37`, `lib/mix/tasks/tak.create.ex:41` (adds `--copy-deps`/`--no-copy-deps`, `--copy-build`/`--no-copy-build`, `config :tak, copy_deps/copy_build`).

Copy optimization: `File.cp_r("deps", "trees/<name>/deps")` (~48ms small, ~469ms large 92M) + skip `deps.get` when `mix.lock` identical. Disable with `--no-copy-deps` for A/B testing. Opt-in `_build` copy: `File.cp_r("_build", ...)` (~60ms small 5.9M, ~253ms large 16M) + text rewrite of absolute parent → worktree path in `.app`/`.mix`/`compile.*` (skips `.beam`), `File.touch` to avoid future mtime warning.

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

Before optimization ( `perf/profiling+fix` , `bench/BENCHMARK.md` ):

```
small (tak): deps.get 92-96% (2.6-3.1s), git 1-4%, mise 0.5%
large demo:  deps.get 99.5% (20-23s cold, warm 2s), git 0.3%
```

After `copy_deps` ( `perf/copy-deps` , default enabled):

```
small: copy_deps 48-85ms (47-61%) + deps.get 0ms (skipped) → total 101-138ms vs 976ms/3.2s without copy (6-10×)
large 92M deps: copy_deps 469-610ms (92-93%) + deps.get 0ms → total 509-586ms vs 6.5s/20s without copy (11-13×)
```

Next:

- `copy_deps` now default; `copy_build` opt-in. Compare 3-way:
  ```bash
  TAK_PROFILE=1 mix tak.create bench/x armstrong --no-db --no-copy-deps --no-copy-build  # original
  TAK_PROFILE=1 mix tak.create bench/x armstrong --no-db --copy-deps --no-copy-build      # default ~101ms small / 509ms large
  TAK_PROFILE=1 mix tak.create bench/x armstrong --no-db --copy-deps --copy-build         # opt-in ~172ms small / 868ms large (+253ms build)
  ```
- `ecto.setup` not yet optimized (still measured as `ecto.setup` row when `--db`; `_build` copy helps first `mix compile` ~200ms vs 3s)
- Test coverage now includes `test/tak/copy_build_test.exs` (rewrites text artefacts, skips `.beam`)

## 5. Test coverage

`test/support/phoenix_demo_generator.ex` + `test/tak/profiling_test.exs` give a fast, offline simulation of the large-LiveView case (15 LiveViews, 80 spans each, 30 events) without needing `phx.new` or network. Run with:

```bash
mix test test/tak/profiling_test.exs --trace
```
