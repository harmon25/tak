#!/usr/bin/env elixir
# Runs a reproducible `tak.create` profiling run against a demo app.
#
# Usage:
#   mix run bench/generate_demo.exs            # once
#   mix run bench/profile_demo.exs             # uses /tmp/tak_phoenix_bench
#   mix run bench/profile_demo.exs /tmp/my_app
#
# What it does:
#   1. cd into the demo app, ensure deps are fetched once (warm cache)
#   2. clean any existing `trees/*` from previous runs
#   3. run `TAK_PROFILE=1 mix tak.create` twice (--no-db and --db) capturing
#      the profiling breakdown
#   4. print a summary table you can paste into a PR or issue
#
# NOTE: Requires Postgres for --db variant; the --no-db variant always runs.
# Set DO_PROFILE_DB=0 to skip the DB variant.

demo = List.first(System.argv()) || Path.join(System.tmp_dir!(), "tak_phoenix_bench")

unless File.dir?(demo) do
  IO.puts("Demo app not found at #{demo}")
  IO.puts("Run `mix run bench/generate_demo.exs` first.")
  System.halt(1)
end

IO.puts("=> Demo app: #{demo}")

# Ensure tak is compiled in the current repo before shelling out via System.cmd inside demo app.
# The demo app will `mix tak.create` – it needs :tak available via path dep or archive.
# Easiest: we create via `mix tak.create` from inside demo, with TAK_PROFILE=1 and MIX_ENV=dev.

defmodule Runner do
  def run(demo, branch, name, extra_args) do
    env = [
      {"TAK_PROFILE", "1"},
      {"MIX_ENV", "dev"}
    ]

    args = ["tak.create", branch, name | extra_args]

    # We do two attempts with --profile: the Mix task in tak will delegate to Tak.Worktrees.create
    {output, status} =
      System.cmd("mix", args,
        cd: demo,
        env: env,
        stderr_to_stdout: true
      )

    {output, status}
  end

  def cleanup(demo) do
    trees = Path.join(demo, "trees")

    if File.dir?(trees) do
      File.rm_rf!(trees)
    end

    # prune git worktree bookkeeping
    System.cmd("git", ["worktree", "prune"], cd: demo, stderr_to_stdout: true)

    # delete bench branches if they were created
    for br <- ["feature/tak-profile-no-db", "feature/tak-profile-db"] do
      System.cmd("git", ["branch", "-D", br], cd: demo, stderr_to_stdout: true)
    end
  end
end

# Warm cache
IO.puts("\n=> Warming deps in demo app (once)...")
{mix_out, _} = System.cmd("mix", ["deps.get"], cd: demo, stderr_to_stdout: true, env: [{"MIX_ENV", "dev"}])
IO.puts(String.slice(mix_out, -500, 500) || "")

# Ensure demo has :tak wired (in case generated without path dep)
mix_path = Path.join(demo, "mix.exs")
mix_content = File.read!(mix_path)

if String.contains?(mix_content, "{:tak,") do
  :ok
else
  tak_path = Path.expand(Path.join(__DIR__, ".."))
  IO.puts("=> Wiring :tak path dep into demo mix.exs (#{tak_path})")

  new_content =
    Regex.replace(~r/defp deps do\s*\[/, mix_content, "defp deps do\n    [{:tak, path: \"#{tak_path}\", only: :dev},\n     ")

  File.write!(mix_path, new_content)
  System.cmd("mix", ["deps.get"], cd: demo, stderr_to_stdout: true, env: [{"MIX_ENV", "dev"}])
end

Runner.cleanup(demo)

IO.puts("\n" <> String.duplicate("=", 70))
IO.puts("RUN 1: --no-db (isolates git + deps.get + file IO, no ecto.setup)")
IO.puts(String.duplicate("=", 70))

{out1, status1} = Runner.run(demo, "feature/tak-profile-no-db", "armstrong", ["--no-db"])
IO.puts(out1)
IO.puts("exit: #{status1}")

# Clean for second run so slots don't clash
Runner.cleanup(demo)

if System.get_env("DO_PROFILE_DB") != "0" do
  IO.puts("\n" <> String.duplicate("=", 70))
  IO.puts("RUN 2: --db (includes mix ecto.setup)")
  IO.puts(String.duplicate("=", 70))

  {out2, status2} = Runner.run(demo, "feature/tak-profile-db", "hickey", [])
  IO.puts(out2)
  IO.puts("exit: #{status2}")
  Runner.cleanup(demo)
else
  IO.puts("\n(skipping --db run; set DO_PROFILE_DB=1 to enable)")
end

IO.puts("\nDone. Paste the [TAK PROFILE] blocks into your optimization notes.")
IO.puts("Tip: run with hyperfine for stable wall-clock:")
IO.puts("  hyperfine --warmup 1 'TAK_PROFILE=1 mix tak.create feature/x armstrong --no-db' --prepare 'mix tak.remove armstrong --force 2>/dev/null; git branch -D feature/x 2>/dev/null; true'")
