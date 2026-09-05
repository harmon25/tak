defmodule Tak.CopyBuildTest do
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
    tmp =
      Path.join(System.tmp_dir!(), "tak_copy_build_test_#{System.unique_integer([:positive])}")

    parent = Path.join(tmp, "parent")
    File.mkdir_p!(parent)

    # Fake parent _build with a text artefact containing parent absolute path
    parent_expanded = Path.expand(parent)
    build_app = Path.join(parent, "_build/dev/lib/fake/ebin/fake.app")
    File.mkdir_p!(Path.dirname(build_app))

    File.write!(
      build_app,
      ~s({application, fake, [{vsn, "1.0"}, {path, "#{parent_expanded}/lib/fake"}]})
    )

    build_lock = Path.join(parent, "_build/dev/.mix/compile.lock")
    File.mkdir_p!(Path.dirname(build_lock))
    File.write!(build_lock, "lock for #{parent_expanded}")

    # Also need deps for copy_deps part
    File.mkdir_p!(Path.join(parent, "deps/fake_dep"))
    File.write!(Path.join(parent, "mix.lock"), ~s(%{"fake_dep" => {:hex, :fake_dep, "1.0.0"}}))

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
    Application.put_env(:tak, :copy_build, true)

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

    {:ok, parent: parent, trees_dir: trees_dir}
  end

  test "copies _build and rewrites parent path", %{trees_dir: trees_dir, parent: parent} do
    TestSystem.configure(fn
      "git", ["show-ref" | _], _ ->
        {"", 1}

      "git", ["worktree", "add", "-b", _, path], _ ->
        File.mkdir_p!(path)
        File.write!(Path.join(path, "mix.lock"), File.read!(Path.join(parent, "mix.lock")))
        {"", 0}

      "mix", ["deps.get"], _ ->
        {"", 0}

      _c, _a, _o ->
        {"", 0}
    end)

    assert {:ok, _} =
             Tak.Worktrees.create("feature/build", "armstrong",
               create_db: false,
               copy_deps: true,
               copy_build: true
             )

    copied_app = Path.join(trees_dir, "armstrong/_build/dev/lib/fake/ebin/fake.app")
    assert File.exists?(copied_app)
    content = File.read!(copied_app)
    child = Path.expand(Path.join(trees_dir, "armstrong"))
    assert content =~ child
    # Content should be rewritten to child/lib/fake, not just parent/lib/fake
    assert content == ~s({application, fake, [{vsn, "1.0"}, {path, "#{child}/lib/fake"}]})
  end

  test "falls back to compile when parent has no _build", %{trees_dir: _} do
    File.rm_rf!("_build")

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
             Tak.Worktrees.create("feature/nobuild", "armstrong",
               create_db: false,
               copy_deps: true,
               copy_build: true
             )

    # No crash, still copies deps
  end

  test "respects --no-copy-build", %{trees_dir: trees_dir, parent: parent} do
    TestSystem.configure(fn
      "git", ["show-ref" | _], _ ->
        {"", 1}

      "git", ["worktree", "add", "-b", _, path], _ ->
        File.mkdir_p!(path)
        File.write!(Path.join(path, "mix.lock"), File.read!(Path.join(parent, "mix.lock")))
        {"", 0}

      "mix", ["deps.get"], _ ->
        {"", 0}

      _c, _a, _o ->
        {"", 0}
    end)

    assert {:ok, _} =
             Tak.Worktrees.create("feature/flag", "armstrong",
               create_db: false,
               copy_deps: true,
               copy_build: false
             )

    refute File.dir?(Path.join(trees_dir, "armstrong/_build"))
  end

  test "shows copy_build in profile breakdown", %{trees_dir: _} do
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
                   copy_build: true,
                   profile: true
                 )
      end)

    assert output =~ "copy_build"
    assert output =~ "copy_deps"
  end

  test "skips .beam files during rewrite", %{trees_dir: trees_dir, parent: parent} do
    # Add a fake beam with parent path inside but should be skipped
    beam = Path.join(parent, "_build/dev/lib/fake/ebin/fake.beam")
    File.write!(beam, "beam with #{Path.expand(parent)} path")

    TestSystem.configure(fn
      "git", ["show-ref" | _], _ ->
        {"", 1}

      "git", ["worktree", "add", "-b", _, path], _ ->
        File.mkdir_p!(path)
        File.write!(Path.join(path, "mix.lock"), File.read!(Path.join(parent, "mix.lock")))
        {"", 0}

      "mix", ["deps.get"], _ ->
        {"", 0}

      _c, _a, _o ->
        {"", 0}
    end)

    assert {:ok, _} =
             Tak.Worktrees.create("feature/beam", "armstrong",
               create_db: false,
               copy_deps: true,
               copy_build: true
             )

    copied = File.read!(Path.join(trees_dir, "armstrong/_build/dev/lib/fake/ebin/fake.beam"))
    # Should still contain parent path because .beam skipped
    assert copied =~ Path.expand(parent)
  end
end
