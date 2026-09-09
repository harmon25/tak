defmodule Tak.ProfilingTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  defmodule TestSystem do
    def configure(handler, executables \\ %{}) do
      Process.put({__MODULE__, :handler}, handler)
      Process.put({__MODULE__, :executables}, executables)
      Process.put({__MODULE__, :history}, [])
    end

    def history do
      Process.get({__MODULE__, :history}, []) |> Enum.reverse()
    end

    def cmd(command, args, opts) do
      Process.put({__MODULE__, :history}, [
        {command, args, opts} | Process.get({__MODULE__, :history}, [])
      ])

      Process.get({__MODULE__, :handler}).(command, args, opts)
    end

    def find_executable(name) do
      Map.get(Process.get({__MODULE__, :executables}, %{}), name)
    end
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "tak_prof_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    previous = %{
      trees_dir: Application.get_env(:tak, :trees_dir),
      names: Application.get_env(:tak, :names),
      system_mod: Application.get_env(:tak, :system_mod),
      profile: Application.get_env(:tak, :profile),
      copy_deps: Application.get_env(:tak, :copy_deps),
      copy_build: Application.get_env(:tak, :copy_build)
    }

    trees_dir = Path.join(tmp, "trees")
    File.mkdir_p!(trees_dir)
    Application.put_env(:tak, :trees_dir, trees_dir)
    Application.put_env(:tak, :names, ["armstrong", "hickey"])
    Application.put_env(:tak, :system_mod, TestSystem)
    Application.put_env(:tak, :copy_deps, false)
    Application.put_env(:tak, :copy_build, false)
    Application.delete_env(:tak, :profile)
    System.delete_env("TAK_PROFILE")

    on_exit(fn ->
      File.rm_rf!(tmp)

      Enum.each(previous, fn
        {k, nil} -> Application.delete_env(:tak, k)
        {k, v} -> Application.put_env(:tak, k, v)
      end)

      System.delete_env("TAK_PROFILE")
    end)

    {:ok, tmp: tmp, trees_dir: trees_dir}
  end

  test "enabled? is false by default" do
    refute Tak.Profiling.enabled?([])
    refute Tak.Profiling.enabled?(profile: false)
  end

  test "enabled? via --profile flag" do
    assert Tak.Profiling.enabled?(profile: true)
  end

  test "enabled? via TAK_PROFILE env" do
    System.put_env("TAK_PROFILE", "1")
    assert Tak.Profiling.enabled?([])
    System.delete_env("TAK_PROFILE")
  end

  test "format_report includes all stages", %{trees_dir: _} do
    report = Tak.Profiling.format_report([{"git worktree add", 120}, {"deps.get", 800}], 920)
    assert report =~ "git worktree add"
    assert report =~ "deps.get"
    assert report =~ "total"
  end

  test "create with --profile prints breakdown", %{trees_dir: trees_dir} do
    TestSystem.configure(fn
      "git", ["show-ref" | _], _ ->
        {"", 1}

      "git", ["worktree", "add", "-b", _, path], _ ->
        File.mkdir_p!(path)
        {"", 0}

      "mix", ["deps.get"], opts ->
        assert opts[:cd] == Path.join(trees_dir, "armstrong")
        {"", 0}

      _c, _a, _o ->
        {"", 0}
    end)

    output =
      capture_io(fn ->
        assert {:ok, _wt} =
                 Tak.Worktrees.create("feature/profile", "armstrong",
                   create_db: false,
                   profile: true
                 )
      end)

    assert output =~ "[TAK PROFILE]"
    assert output =~ "resolve_name"
    assert output =~ "git worktree add"
    assert output =~ "deps.get"
  end

  test "create with TAK_PROFILE=1 and simulated large liveviews", %{
    tmp: tmp,
    trees_dir: trees_dir
  } do
    # Simulate a demo app file tree with 15 large LiveViews (like bench/generate_demo.exs)
    demo = Tak.Support.PhoenixDemoGenerator.generate(tmp)
    # Point trees_dir inside the demo so File writes land there (closer to real bench)
    Application.put_env(:tak, :trees_dir, Path.join(demo, "trees"))
    System.put_env("TAK_PROFILE", "1")

    TestSystem.configure(fn
      "git", ["show-ref" | _], _ ->
        {"", 1}

      "git", ["worktree", "add", "-b", _, path], _ ->
        File.mkdir_p!(path)
        {"", 0}

      "mix", ["deps.get"], _ ->
        Process.sleep(15)
        {"", 0}

      "mix", ["ecto.setup"], _ ->
        Process.sleep(25)
        {"", 0}

      _c, _a, _o ->
        {"", 0}
    end)

    output =
      capture_io(fn ->
        assert {:ok, wt} =
                 Tak.Worktrees.create("feature/demo-live", "armstrong",
                   create_db: true,
                   profile: false
                 )

        # Env var should still trigger profiling even without profile: true
        assert wt.name == "armstrong"
      end)

    # Because we use env var, do_create_profiled should have run
    assert output =~ "[TAK PROFILE]"
    assert output =~ "ecto.setup"
    assert output =~ "metadata_write"

    # Also test that the demo actually has large files
    live_files = Path.wildcard(Path.join([demo, "lib", "**", "*_live.ex"]))
    assert length(live_files) == 15
    assert File.stat!(hd(live_files)).size > 800

    System.delete_env("TAK_PROFILE")
    Application.put_env(:tak, :trees_dir, trees_dir)
  end

  test "create without profile prints nothing (no overhead)", %{trees_dir: _trees_dir} do
    TestSystem.configure(fn
      "git", ["show-ref" | _], _ ->
        {"", 1}

      "git", ["worktree", "add", "-b", _, path], _ ->
        File.mkdir_p!(path)
        {"", 0}

      "mix", ["deps.get"], _ ->
        {"", 0}

      _c, _a, _o ->
        {"", 0}
    end)

    output =
      capture_io(fn ->
        assert {:ok, _} =
                 Tak.Worktrees.create("feature/no-profile", "armstrong", create_db: false)
      end)

    refute output =~ "[TAK PROFILE]"
  end
end
