defmodule Tak.Support.PhoenixDemoGenerator do
  @moduledoc """
  Test helper that generates a heavy Phoenix-like project in a temp dir
  without hitting the network for `mix deps.get`.

  Used by `test/tak/profiling_test.exs` as a realistic file-tree benchmark.
  For a full `mix phx.new` demo, see `bench/generate_demo.exs`.
  """

  @app "tak_bench_demo"
  @module "TakBenchDemo"

  def generate(tmp) do
    dest = Path.join(tmp, "phoenix_demo")
    File.mkdir_p!(dest)

    # Minimal mix project with some deps to make `mix deps.get` realistic but offline
    File.write!(Path.join(dest, "mix.exs"), mix_exs())
    File.write!(Path.join(dest, ".gitignore"), "/_build\n/deps\n/trees\n")
    File.mkdir_p!(Path.join(dest, "config"))
    File.write!(Path.join(dest, "config/config.exs"), config_exs())
    File.write!(Path.join(dest, "config/dev.exs"), "import Config\n")
    File.write!(Path.join(dest, "config/dev.local.exs"), "import Config\n")

    # Init git (tak requires git worktree)
    System.cmd("git", ["init", "-q"], cd: dest)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: dest)
    System.cmd("git", ["config", "user.name", "Test"], cd: dest)
    File.write!(Path.join(dest, "README.md"), "# demo")
    System.cmd("git", ["add", "."], cd: dest)
    System.cmd("git", ["commit", "-m", "init", "-q"], cd: dest)

    live_dir = Path.join([dest, "lib", "#{@app}_web", "live"])
    File.mkdir_p!(live_dir)

    for i <- 1..15 do
      name = "Demo#{i}"
      path = Path.join(live_dir, "demo#{i}_live.ex")
      File.write!(path, large_live(name, i))
    end

    dest
  end

  defp mix_exs do
    """
    defmodule #{@module}.MixProject do
      use Mix.Project
      def project, do: [app: :#{@app}, version: "0.1.0", elixir: "~> 1.15", deps: deps()]
      def application, do: [extra_applications: [:logger]]
      defp deps, do: [{:phoenix, "~> 1.8"}, {:phoenix_live_view, "~> 1.0"}, {:ecto, "~> 3.12"}]
    end
    """
  end

  defp config_exs do
    """
    import Config
    if File.exists?("\#{__DIR__}/\#{config_env()}.local.exs") do
      import_config "\#{config_env()}.local.exs"
    end
    """
  end

  defp large_live(name, idx) do
    """
    defmodule #{@module}Web.#{name}Live do
      use Phoenix.LiveView

      def mount(_p, _s, socket) do
        {:ok, assign(socket, :n, #{idx})}
      end

      def render(assigns) do
        ~H\"\"\"
        <div>#{String.duplicate("<span>#{name}</span>", 80)}</div>
        <p><%= @n %></p>
        \"\"\"
      end

      #{Enum.map_join(1..30, "\n  ", fn i -> "def handle_event(\"ev#{i}\", _, s), do: {:noreply, s}" end)}
    end
    """
  end
end
