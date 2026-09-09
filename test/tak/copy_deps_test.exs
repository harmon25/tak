defmodule Tak.CopyDepsTest do
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
    tmp = Path.join(System.tmp_dir!(), "tak_copy_test_#{System.unique_integer([:positive])}")
    parent = Path.join(tmp, "parent")
    File.mkdir_p!(parent)

    # Create fake parent deps and mix.lock
    File.mkdir_p!(Path.join(parent, "deps/fake_dep"))
    File.write!(Path.join(parent, "deps/fake_dep/mix.exs"), "# fake")
    File.write!(Path.join(parent, "mix.lock"), ~s(%{"fake_dep" => {:hex, :fake_dep, "1.0.0"}}))

    # Create trees dir inside parent (simulates real project layout)
    trees_dir = Path.join(parent, "trees")
    File.mkdir_p!(trees_dir)

    previous = %{
      trees_dir: Application.get_env(:tak, :trees_dir),
      names: Application.get_env(:tak, :names),
      system_mod: Application.get_env(:tak, :system_mod),
      copy_deps: Application.get_env(:tak, :copy_deps),
      copy_build: Application.get_env(:tak, :copy_build)
    }

    Application.put_env(:tak, :trees_dir, trees_dir)
    Application.put_env(:tak, :names, ["armstrong", "hickey"])
    Application.put_env(:tak, :system_mod, TestSystem)
    Application.put_env(:tak, :copy_deps, true)
    Application.put_env(:tak, :copy_build, false)

    # We need to cd into parent for File.dir?("deps") to resolve correctly
    old_cwd = File.cwd!()
    File.cd!(parent)

    on_exit(fn ->
      File.cd!(old_cwd)
      File.rm_rf!(tmp)

      Enum.each(previous, fn
        {k, nil} -> Application.delete_env(:tak, k)
        {k, v} -> Application.put_env(:tak, k, v)
      end)
    end)

    {:ok, parent: parent, trees_dir: trees_dir, tmp: tmp}
  end

  test "copies deps and skips deps.get when lock in sync", %{trees_dir: trees_dir, parent: parent} do
    TestSystem.configure(fn
      "git", ["show-ref" | _], _ ->
        {"", 1}

      "git", ["worktree", "add", "-b", _, path], _ ->
        File.mkdir_p!(path)
        File.write!(Path.join(path, "mix.lock"), File.read!(Path.join(parent, "mix.lock")))
        {"", 0}

      "mix", ["deps.get"], _ ->
        flunk("deps.get should be skipped when copy succeeds and lock in sync")

      "mix", ["ecto.setup"], _ ->
        {"", 0}

      _c, _a, _o ->
        {"", 0}
    end)

    assert {:ok, wt} =
             Tak.Worktrees.create("feature/copy", "armstrong", create_db: false, copy_deps: true)

    assert wt.name == "armstrong"
    assert File.dir?(Path.join(trees_dir, "armstrong/deps/fake_dep"))

    refute Enum.any?(TestSystem.history(), fn {cmd, args, _} ->
             cmd == "mix" and args == ["deps.get"]
           end)
  end

  test "falls back to deps.get when parent has no deps", %{trees_dir: _trees_dir} do
    File.rm_rf!("deps")

    TestSystem.configure(fn
      "git", ["show-ref" | _], _ ->
        {"", 1}

      "git", ["worktree", "add", "-b", _, path], _ ->
        File.mkdir_p!(path)
        File.write!(Path.join(path, "mix.lock"), ~s(%{}))
        {"", 0}

      "mix", ["deps.get"], _ ->
        {"", 0}

      _c, _a, _o ->
        {"", 0}
    end)

    assert {:ok, _} =
             Tak.Worktrees.create("feature/nocache", "armstrong",
               create_db: false,
               copy_deps: true
             )

    assert Enum.any?(TestSystem.history(), fn {cmd, args, _} ->
             cmd == "mix" and args == ["deps.get"]
           end)
  end

  test "respects --no-copy-deps flag", %{trees_dir: _} do
    TestSystem.configure(fn
      "git", ["show-ref" | _], _ ->
        {"", 1}

      "git", ["worktree", "add", "-b", _, path], _ ->
        File.mkdir_p!(path)
        File.write!(Path.join(path, "mix.lock"), File.read!("mix.lock"))
        {"", 0}

      "mix", ["deps.get"], _ ->
        {"", 0}

      _c, _a, _o ->
        {"", 0}
    end)

    assert {:ok, _} =
             Tak.Worktrees.create("feature/flag", "armstrong", create_db: false, copy_deps: false)

    assert Enum.any?(TestSystem.history(), fn {cmd, args, _} ->
             cmd == "mix" and args == ["deps.get"]
           end)
  end

  test "shows copy_deps in profile breakdown", %{trees_dir: _} do
    TestSystem.configure(fn
      "git", ["show-ref" | _], _ ->
        {"", 1}

      "git", ["worktree", "add", "-b", _, path], _ ->
        File.mkdir_p!(path)
        File.write!(Path.join(path, "mix.lock"), File.read!("mix.lock"))
        {"", 0}

      "mix", ["deps.get"], _ ->
        {"", 0}

      _c, _a, _o ->
        {"", 0}
    end)

    output =
      capture_io(fn ->
        assert {:ok, _} =
                 Tak.Worktrees.create("feature/prof", "armstrong",
                   create_db: false,
                   copy_deps: true,
                   profile: true
                 )
      end)

    assert output =~ "copy_deps"
    assert output =~ "deps.get"
  end

  test "deps.get not skipped when lock mismatch", %{parent: _parent} do
    TestSystem.configure(fn
      "git", ["show-ref" | _], _ ->
        {"", 1}

      "git", ["worktree", "add", "-b", _, path], _ ->
        File.mkdir_p!(path)
        # Worktree gets different lock
        File.write!(Path.join(path, "mix.lock"), ~s(%{"other" => {:hex, :other, "2.0"}}))
        {"", 0}

      "mix", ["deps.get"], _ ->
        {"", 0}

      _c, _a, _o ->
        {"", 0}
    end)

    assert {:ok, _} =
             Tak.Worktrees.create("feature/mismatch", "armstrong",
               create_db: false,
               copy_deps: true
             )

    assert Enum.any?(TestSystem.history(), fn {cmd, args, _} ->
             cmd == "mix" and args == ["deps.get"]
           end)
  end
end
