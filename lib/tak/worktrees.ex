defmodule Tak.Worktrees do
  @moduledoc """
  Public runtime API for Tak worktree lifecycle operations.

  The supported surface is intentionally small:

    * `create/3` creates a worktree and returns `%Tak.Worktree{}` data
    * `list/0` reports the main repo and known worktrees with runtime status
    * `remove/2` removes a worktree and returns `%Tak.RemoveResult{}` data
    * `doctor/0` returns structured environment checks for CLI rendering

  Tak uses three public data shapes:

    * `Tak.Worktree`, stable worktree identity and configuration
    * `Tak.WorktreeStatus`, transient runtime status layered on top of a worktree
    * `Tak.RemoveResult`, removal outcome layered on top of a worktree
  """

  require Logger

  @doc """
  Creates a worktree. Returns `{:ok, %Tak.Worktree{}}` or `{:error, reason}`.

  When `name` is `nil`, the first available slot is picked automatically.

  The core API does not raise for expected git or mix command failures. Those
  return tagged errors instead:

    * `{:git_failed, command, output}`
    * `{:bootstrap_failed, command, output}`
    * `{:bootstrap_failed, command, output, :cleanup_failed}`

  ## Options

    * `:create_db` - whether to create the database (default: from config)
    * `:copy_deps` - whether to copy `deps/` from parent instead of `mix deps.get` (default: from config)
  """
  def create(branch, name, opts \\ []) do
    if Tak.Profiling.enabled?(opts) do
      do_create_profiled(branch, name, opts)
    else
      do_create(branch, name, opts)
    end
  end

  defp do_create(branch, name, opts) do
    create_db = Keyword.get(opts, :create_db, Tak.create_database?())

    with {:ok, name} <- resolve_name(name),
         :ok <- validate_not_exists(name) do
      trees_dir = Tak.trees_dir()
      worktree_path = Path.join(trees_dir, name)
      branch_exists? = Tak.Git.branch_exists?(branch)

      worktree = %Tak.Worktree{
        name: name,
        branch: branch,
        port: Tak.port_for(name),
        path: worktree_path,
        database: if(create_db, do: Tak.database_for(name)),
        database_managed?: create_db
      }

      maybe_warn_port_in_use(worktree.port)
      File.mkdir_p!(trees_dir)

      with {:ok, _output} <- add_git_worktree(branch, worktree_path, branch_exists?),
           :ok <- copy_env_file(worktree_path),
           :ok <- write_dev_local_config(worktree.path, worktree.name, worktree.port, create_db),
           :ok <- maybe_write_mise_config(worktree.path, worktree.port),
           :ok <- bootstrap_worktree(worktree.path, create_db, opts) do
        Tak.Metadata.write!(worktree)
        {:ok, worktree}
      else
        {:error, {:git_failed, _command, _output} = reason} ->
          {:error, reason}

        {:error, {:bootstrap_failed, _command, _output} = reason} ->
          {:error, cleanup_after_bootstrap_failure(worktree, branch_exists?, reason)}
      end
    end
  end

  defp do_create_profiled(branch, name, opts) do
    create_db = Keyword.get(opts, :create_db, Tak.create_database?())
    prof = Tak.Profiling.start()

    {resolve_result, prof} =
      Tak.Profiling.measure(prof, "resolve_name", fn -> resolve_name(name) end)

    case resolve_result do
      {:error, _} = err ->
        {timings, total} = Tak.Profiling.finish(prof)
        Tak.Profiling.report(timings, total)
        err

      {:ok, resolved_name} ->
        {validate_result, prof} =
          Tak.Profiling.measure(prof, "validate_not_exists", fn ->
            validate_not_exists(resolved_name)
          end)

        case validate_result do
          {:error, _} = err ->
            {timings, total} = Tak.Profiling.finish(prof)
            Tak.Profiling.report(timings, total)
            err

          :ok ->
            {branch_exists?, prof} =
              Tak.Profiling.measure(prof, "branch_exists?", fn ->
                {Tak.Git.branch_exists?(branch), nil}
              end)
              |> then(fn {{val, _}, p} -> {val, p} end)

            trees_dir = Tak.trees_dir()
            worktree_path = Path.join(trees_dir, resolved_name)

            worktree = %Tak.Worktree{
              name: resolved_name,
              branch: branch,
              port: Tak.port_for(resolved_name),
              path: worktree_path,
              database: if(create_db, do: Tak.database_for(resolved_name)),
              database_managed?: create_db
            }

            {_port_check, prof} =
              Tak.Profiling.measure(prof, "port_check", fn ->
                maybe_warn_port_in_use(worktree.port)
              end)

            {_mkdir, prof} =
              Tak.Profiling.measure(prof, "mkdir_trees", fn ->
                File.mkdir_p!(trees_dir)
              end)

            {git_result, prof} =
              Tak.Profiling.measure(prof, "git worktree add", fn ->
                add_git_worktree(branch, worktree_path, branch_exists?)
              end)

            case git_result do
              {:error, {:git_failed, _, _} = reason} ->
                {timings, total} = Tak.Profiling.finish(prof)
                Tak.Profiling.report(timings, total)
                {:error, reason}

              {:ok, _output} ->
                {_copy, prof} =
                  Tak.Profiling.measure(prof, "copy_env", fn ->
                    copy_env_file(worktree_path)
                  end)

                {cfg_result, prof} =
                  Tak.Profiling.measure(prof, "write_dev_local", fn ->
                    write_dev_local_config(
                      worktree.path,
                      worktree.name,
                      worktree.port,
                      create_db
                    )
                  end)

                case cfg_result do
                  {:error, _} = err ->
                    {timings, total} = Tak.Profiling.finish(prof)
                    Tak.Profiling.report(timings, total)
                    err

                  :ok ->
                    {mise_result, prof} =
                      Tak.Profiling.measure(prof, "mise_config", fn ->
                        maybe_write_mise_config(worktree.path, worktree.port)
                      end)

                    case mise_result do
                      {:error, _} = err ->
                        {timings, total} = Tak.Profiling.finish(prof)
                        Tak.Profiling.report(timings, total)
                        err

                      :ok ->
                        {_copy, prof} =
                          Tak.Profiling.measure(prof, "copy_deps", fn ->
                            maybe_copy_deps(worktree.path, opts)
                          end)

                        {_bcopy, prof} =
                          Tak.Profiling.measure(prof, "copy_build", fn ->
                            maybe_copy_build(worktree.path, opts)
                          end)

                        {deps_result, prof} =
                          Tak.Profiling.measure(prof, "deps.get", fn ->
                            maybe_run_deps_get(worktree.path, opts)
                          end)

                        {bootstrap_outcome, prof} =
                          case deps_result do
                            {:error, _} = err ->
                              {err, prof}

                            {:ok, _} ->
                              if create_db do
                                Tak.Profiling.measure(prof, "ecto.setup", fn ->
                                  maybe_setup_database(worktree.path, true)
                                end)
                              else
                                {:ok, prof}
                              end
                          end

                        case bootstrap_outcome do
                          :ok ->
                            {_meta, prof} =
                              Tak.Profiling.measure(prof, "metadata_write", fn ->
                                Tak.Metadata.write!(worktree)
                              end)

                            {timings, total} = Tak.Profiling.finish(prof)
                            Tak.Profiling.report(timings, total)
                            {:ok, worktree}

                          {:error, {:bootstrap_failed, _, _} = reason} ->
                            cleanup =
                              cleanup_after_bootstrap_failure(worktree, branch_exists?, reason)

                            {timings, total} = Tak.Profiling.finish(prof)
                            Tak.Profiling.report(timings, total)
                            {:error, cleanup}
                        end
                    end
                end
            end
        end
    end
  end

  @doc """
  Lists the main repository and all known worktrees.

  Returns `{main, worktrees}` where `main` is a `%Tak.WorktreeStatus{}` for the
  current repository and `worktrees` is a list of `%Tak.WorktreeStatus{}`
  values for entries found in `Tak.trees_dir/0`.

  Status is `:running`, `:stopped`, or `:unknown`.
  """
  def list do
    trees_dir = Tak.trees_dir()
    base_port = Tak.base_port()

    {main_status, main_pid} = check_port(base_port)

    main = %Tak.WorktreeStatus{
      worktree: %Tak.Worktree{
        name: "main",
        branch: Tak.Git.current_branch(),
        port: base_port,
        path: Path.expand("."),
        database: nil,
        database_managed?: false
      },
      status: main_status,
      pid: main_pid
    }

    worktrees =
      if File.dir?(trees_dir) do
        trees_dir
        |> File.ls!()
        |> Enum.filter(&File.dir?(Path.join(trees_dir, &1)))
        |> Enum.map(fn name ->
          worktree_path = Path.join(trees_dir, name)
          load_worktree_status(name, worktree_path)
        end)
      else
        []
      end

    {main, worktrees}
  end

  @doc """
  Removes a worktree. Returns `{:ok, %Tak.RemoveResult{}}` or `{:error, reason}`.

  ## Options

    * `:force` - force removal even with uncommitted changes (default: false)
    * `:keep_db` - keep the database instead of dropping it (default: false)
  """
  def remove(name, opts \\ []) do
    force = Keyword.get(opts, :force, false)
    keep_db = Keyword.get(opts, :keep_db, false)
    trees_dir = Tak.trees_dir()
    worktree_path = Path.join(trees_dir, name)

    if not File.dir?(worktree_path) do
      {:error, {:not_found, name}}
    else
      status = load_worktree_status(name, worktree_path)
      worktree = status.worktree

      if worktree.port, do: Tak.Port.kill(worktree.port)

      with :ok <- remove_git_worktree(worktree_path, force),
           :ok <- maybe_delete_branch(worktree.branch, force) do
        best_effort_prune_worktrees()
        database_cleanup = maybe_cleanup_database(worktree, keep_db)
        {:ok, %Tak.RemoveResult{worktree: worktree, database_cleanup: database_cleanup}}
      end
    end
  end

  @doc """
  Runs doctor checks. Returns `{passed, failed, results}` where results is a
  list of `{:ok | :error | :warn, message}` tuples.
  """
  def doctor do
    results = [
      check_dev_local_import(),
      check_gitignore("dev.local.exs", "config/dev.local.exs", required: true),
      check_gitignore(".tak", ".tak", required: true),
      check_gitignore("mise.local.toml", "mise.local.toml",
        required: false,
        note: "only needed if using mise"
      ),
      check_gitignore(Tak.trees_dir(), "#{Tak.trees_dir()}/", required: true),
      check_executable("git", required: true),
      check_executable("dropdb", required: false, note: "needed for tak.remove")
    ]

    passed = Enum.count(results, &match?({:ok, _}, &1))
    failed = Enum.count(results, &match?({:error, _, _}, &1))

    {passed, failed, results}
  end

  defp maybe_warn_port_in_use(nil), do: :ok

  defp maybe_warn_port_in_use(port) do
    if Tak.Port.in_use?(port) do
      Logger.warning("Tak worktree port #{port} is already in use")
    end

    :ok
  end

  defp pick_available_name do
    trees_dir = Tak.trees_dir()

    available =
      Enum.filter(Tak.names(), fn name ->
        not File.dir?(Path.join(trees_dir, name))
      end)

    case available do
      [] -> {:error, :no_slots}
      [first | _] -> {:ok, first}
    end
  end

  defp add_git_worktree(branch, worktree_path, true) do
    run_git(["worktree", "add", worktree_path, branch], :git_failed)
  end

  defp add_git_worktree(branch, worktree_path, false) do
    run_git(["worktree", "add", "-b", branch, worktree_path], :git_failed)
  end

  defp cleanup_after_bootstrap_failure(
         worktree,
         branch_exists?,
         {:bootstrap_failed, command, output}
       ) do
    cleanup_result =
      with :ok <- remove_git_worktree(worktree.path, true),
           :ok <- prune_worktrees(),
           :ok <- maybe_delete_created_branch(worktree.branch, branch_exists?) do
        :ok
      end

    case cleanup_result do
      :ok ->
        {:bootstrap_failed, command, output}

      _ ->
        {:bootstrap_failed, command, output, :cleanup_failed}
    end
  end

  defp remove_git_worktree(worktree_path, force) do
    args =
      if force,
        do: ["worktree", "remove", "--force", worktree_path],
        else: ["worktree", "remove", worktree_path]

    case run_git(args, :worktree_remove_failed) do
      {:ok, _output} ->
        File.rm_rf(worktree_path)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp prune_worktrees do
    case run_git(["worktree", "prune"], :git_prune_failed) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp best_effort_prune_worktrees do
    case prune_worktrees() do
      :ok ->
        :ok

      {:error, {_tag, command, output}} ->
        Logger.warning("Tak prune failed after worktree removal: #{command}\n#{output}")
        :ok
    end
  end

  defp maybe_delete_branch(nil, _force), do: :ok

  defp maybe_delete_branch(branch, force) do
    delete_flag = if force, do: "-D", else: "-d"

    case run_git(["branch", delete_flag, branch], :branch_delete_failed) do
      {:ok, _output} -> :ok
      {:error, _reason} when not force -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_delete_created_branch(_branch, true), do: :ok
  defp maybe_delete_created_branch(nil, false), do: :ok

  defp maybe_delete_created_branch(branch, false) do
    case run_git(["branch", "-D", branch], :branch_delete_failed) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_cleanup_database(%Tak.Worktree{database_managed?: false}, _keep_db), do: nil
  defp maybe_cleanup_database(%Tak.Worktree{database: nil}, _keep_db), do: nil
  defp maybe_cleanup_database(%Tak.Worktree{}, true), do: :kept

  defp maybe_cleanup_database(%Tak.Worktree{database: database}, false) do
    case Tak.System.cmd("dropdb", [database], stderr_to_stdout: true) do
      {_, 0} -> :dropped
      _ -> :failed
    end
  end

  defp copy_env_file(worktree_path) do
    if File.exists?(".env") do
      File.cp!(".env", Path.join(worktree_path, ".env"))
    end

    :ok
  end

  defp bootstrap_worktree(path, create_db, opts \\ []) do
    with :ok <- maybe_copy_deps(path, opts),
         :ok <- maybe_copy_build(path, opts),
         {:ok, _output} <- maybe_run_deps_get(path, opts),
         :ok <- maybe_setup_database(path, create_db) do
      :ok
    end
  end

  defp maybe_copy_deps(path, opts) do
    copy? = Keyword.get(opts, :copy_deps, Tak.copy_deps?())

    if not copy? or not File.dir?("deps") do
      :ok
    else
      dest = Path.join(path, "deps")

      # Remove stale dest to ensure fresh copy (git worktree is fresh)
      File.rm_rf(dest)

      result =
        case File.cp_r("deps", dest) do
          {:ok, _} ->
            :ok

          {:error, reason, file} ->
            Logger.warning(
              "Tak copy deps failed #{file}: #{inspect(reason)}, falling back to deps.get"
            )

            :ok
        end

      # Also copy mix.lock if parent has it but worktree doesn't (e.g. synthetic demo where lock not yet committed)
      parent_lock = "mix.lock"
      worktree_lock = Path.join(path, "mix.lock")

      if File.exists?(parent_lock) and not File.exists?(worktree_lock) do
        File.cp(parent_lock, worktree_lock)
      end

      result
    end
  end

  defp maybe_copy_build(path, opts) do
    copy? = Keyword.get(opts, :copy_build, Tak.copy_build?())

    if not copy? or not File.dir?("_build") do
      :ok
    else
      dest = Path.join(path, "_build")
      File.rm_rf(dest)

      result =
        case File.cp_r("_build", dest) do
          {:ok, _} ->
            :ok

          {:error, reason, file} ->
            Logger.warning("Tak copy _build failed #{file}: #{inspect(reason)}")
            :ok
        end

      rewrite_build_paths(path)
      result
    end
  end

  defp rewrite_build_paths(worktree_path) do
    parent = File.cwd!() |> Path.expand()
    child = Path.expand(worktree_path)

    # Only rewrite text artefacts; skip .beam to avoid corruption
    patterns = [
      Path.join(worktree_path, "_build/**/*.app"),
      Path.join(worktree_path, "_build/**/compile.*"),
      Path.join(worktree_path, "_build/**/.mix/*"),
      Path.join(worktree_path, "_build/**/consolidated/*"),
      Path.join(worktree_path, "_build/**/*.lock")
    ]

    files =
      Enum.flat_map(patterns, &Path.wildcard/1)
      |> Enum.filter(&File.regular?/1)

    Enum.each(files, fn file ->
      case File.read(file) do
        {:ok, content} ->
          if String.contains?(content, parent) and not String.contains?(file, ".beam") do
            # Only rewrite if file is textual (avoid binary)
            if String.valid?(content) do
              File.write!(file, String.replace(content, parent, child))
            end
          end

        _ ->
          :ok
      end
    end)

    # Reset mtimes to avoid "was set to the future" warnings
    Path.wildcard(Path.join(worktree_path, "_build/**/*"))
    |> Enum.each(fn f ->
      if File.exists?(f), do: File.touch(f)
    end)

    :ok
  rescue
    _ -> :ok
  end

  defp maybe_run_deps_get(path, opts) do
    copy? = Keyword.get(opts, :copy_deps, Tak.copy_deps?())

    if copy? and File.dir?(Path.join(path, "deps")) and deps_in_sync?(path) do
      {:ok, ""}
    else
      run_mix(path, ["deps.get"])
    end
  end

  defp deps_in_sync?(worktree_path) do
    parent_lock = "mix.lock"
    worktree_lock = Path.join(worktree_path, "mix.lock")

    File.exists?(parent_lock) and File.exists?(worktree_lock) and
      File.read!(parent_lock) == File.read!(worktree_lock)
  end

  defp maybe_setup_database(_path, false), do: :ok

  defp maybe_setup_database(path, true) do
    case run_mix(path, ["ecto.setup"]) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_git(args, tag) do
    case Tak.Git.run(args) do
      {:ok, output} -> {:ok, output}
      {:error, output} -> {:error, {tag, Enum.join(["git" | args], " "), output}}
    end
  end

  defp run_mix(path, args) do
    command = Enum.join(["mix" | args], " ")

    case Tak.System.cmd("mix", args, cd: path, stderr_to_stdout: true, env: [{"MIX_ENV", "dev"}]) do
      {output, 0} -> {:ok, output}
      {output, _} -> {:error, {:bootstrap_failed, command, output}}
    end
  end

  defp resolve_name(nil), do: pick_available_name()

  defp resolve_name(name) do
    if name in Tak.names(), do: {:ok, name}, else: {:error, {:invalid_name, name}}
  end

  defp validate_not_exists(name) do
    path = Path.join(Tak.trees_dir(), name)
    if File.dir?(path), do: {:error, {:already_exists, name}}, else: :ok
  end

  defp load_worktree_status(name, worktree_path) do
    worktree =
      case Tak.Metadata.read(worktree_path) do
        %Tak.Worktree{} = wt ->
          %Tak.Worktree{wt | branch: wt.branch || Tak.Git.worktree_branch(worktree_path)}

        nil ->
          branch = Tak.Git.worktree_branch(worktree_path)
          port = Tak.Config.get_port(worktree_path)
          has_db = Tak.Config.has_database?(worktree_path)

          %Tak.Worktree{
            name: name,
            branch: branch,
            port: port,
            path: worktree_path,
            database: if(has_db, do: Tak.database_for(name)),
            database_managed?: has_db
          }
      end

    {status, pid} = check_port(worktree.port)

    %Tak.WorktreeStatus{
      worktree: worktree,
      status: status,
      pid: pid
    }
  end

  defp check_port(nil), do: {:unknown, nil}

  defp check_port(port) do
    if Tak.Port.in_use?(port) do
      {:running, Tak.Port.pid(port)}
    else
      {:stopped, nil}
    end
  end

  defp write_dev_local_config(worktree_path, name, port, create_db) do
    app_name = Tak.app_name()
    endpoint = inspect(Tak.endpoint())
    repo = inspect(Tak.repo())

    config_dir = Path.join(worktree_path, "config")
    File.mkdir_p!(config_dir)
    dest_path = Path.join(config_dir, "dev.local.exs")
    source_path = "config/dev.local.exs"

    db_config =
      if create_db do
        database = Tak.database_for(name)

        """

        config :#{app_name}, #{repo},
          database: "#{database}"
        """
      else
        ""
      end

    tak_config =
      """

      # Tak worktree config (#{name})
      # These values override any earlier config above
      config :#{app_name}, #{endpoint},
        http: [port: #{port}]
      """ <> db_config

    if File.exists?(source_path) do
      existing = File.read!(source_path)
      File.write!(dest_path, existing <> tak_config)
    else
      File.write!(dest_path, "import Config" <> tak_config)
    end

    :ok
  end

  defp maybe_write_mise_config(worktree_path, port) do
    if Tak.mise_available?() do
      do_write_mise_config(worktree_path, port)
    else
      :ok
    end
  end

  defp do_write_mise_config(worktree_path, port) do
    mise_config = """
    [env]
    PORT = "#{port}"
    """

    mise_path = Path.join(worktree_path, "mise.local.toml")
    File.write!(mise_path, mise_config)
    Tak.System.cmd("mise", ["trust", mise_path], stderr_to_stdout: true)
    :ok
  end

  # --- Doctor checks ---

  defp check_dev_local_import do
    config_path = "config/config.exs"

    cond do
      not File.exists?(config_path) ->
        {:error, "config/config.exs imports local overrides", "File not found"}

      true ->
        content = File.read!(config_path)

        if Regex.match?(~r/import_config.*\.local\.exs/, content) do
          {:ok, "config/config.exs imports local overrides"}
        else
          {:error, "config/config.exs imports local overrides", "Missing import"}
        end
    end
  end

  defp check_gitignore(pattern, display, opts) do
    required = Keyword.get(opts, :required, true)
    note = Keyword.get(opts, :note)
    gitignore_path = ".gitignore"

    cond do
      not File.exists?(gitignore_path) ->
        if required,
          do: {:error, "#{display} in .gitignore", ".gitignore not found"},
          else: {:warn, "#{display} in .gitignore", note}

      true ->
        content = File.read!(gitignore_path)
        lines = String.split(content, "\n")

        found =
          Enum.any?(lines, fn line ->
            line = String.trim(line)

            cond do
              String.starts_with?(line, "#") -> false
              line == "" -> false
              String.contains?(line, pattern) -> true
              true -> false
            end
          end)

        cond do
          found -> {:ok, "#{display} in .gitignore"}
          required -> {:error, "#{display} in .gitignore", "Not ignored"}
          true -> {:warn, "#{display} in .gitignore", note}
        end
    end
  end

  defp check_executable(name, opts) do
    required = Keyword.get(opts, :required, true)
    note = Keyword.get(opts, :note)

    if Tak.System.find_executable(name) do
      {:ok, "#{name} available"}
    else
      if required,
        do: {:error, "#{name} available", "Not found"},
        else: {:warn, "#{name} available", "Not found (#{note})"}
    end
  end
end
