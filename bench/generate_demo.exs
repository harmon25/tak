#!/usr/bin/env elixir
# Generates a realistic Phoenix-like demo project with many large LiveViews
# for benchmarking `tak.create`.
#
# Usage:
#   mix run bench/generate_demo.exs              # -> /tmp/tak_phoenix_bench
#   mix run bench/generate_demo.exs /path/to/app # custom destination
#
# The generated app is a real `mix phx.new` project plus ~15 large LiveViews
# (each 400-800 lines) and a handful of Ecto schemas/migrations so that
# `mix deps.get` and `mix compile` / `mix ecto.setup` have something to chew on
# while remaining "relatively small" (i.e. not 500kLOC).

dest = List.first(System.argv()) || Path.join(System.tmp_dir!(), "tak_phoenix_bench")
app_name = "tak_bench_demo"
module_name = "TakBenchDemo"

if File.exists?(dest) do
  IO.puts("Destination #{dest} already exists – removing...")
  File.rm_rf!(dest)
end

IO.puts("=> mix phx.new #{dest} --app #{app_name} ...")

# Use phx_new archive installed earlier; --no-install keeps it fast/offline
{output, 0} =
  System.cmd("mix", ["phx.new", dest, "--app", app_name, "--no-install", "--no-dashboard", "--no-mailer"],
    stderr_to_stdout: true
  )

IO.puts(output)

# Generate many large LiveViews
live_dir = Path.join([dest, "lib", "#{app_name}_web", "live"])
File.mkdir_p!(live_dir)

defmodule Generator do
  def large_live(name, index, module_name) do
    mod = "#{module_name}Web.#{name}Live"
    assigns = for i <- 1..25, do: "assign(:field_#{i}, #{i * index})"

    heex_rows =
      for i <- 1..40 do
        ~s(<div class="row-#{i}"><span><%= @field_#{rem(i, 25) + 1} %></span><button phx-click="inc_#{i}">Inc #{i}</button></div>)
      end

    handles =
      for i <- 1..40 do
        """
        def handle_event("inc_#{i}", _params, socket) do
          {:noreply, update(socket, :field_#{rem(i, 25) + 1}, &(&1 + 1))}
        end
        """
      end

    """
    defmodule #{mod} do
      use #{module_name}Web, :live_view

      def mount(_params, _session, socket) do
        socket =
          socket
          |> #{Enum.join(assigns, "\n      |> ")}

        {:ok, socket}
      end

      def render(assigns) do
        ~H\"\"\"
        <div id="#{Macro.underscore(name)}-#{index}">
          <h1>#{name} #{index} – #{String.duplicate("LargeLiveView ", 12)}</h1>
          #{Enum.join(heex_rows, "\n      ")}
          <p><%= @field_1 %> – #{String.duplicate("lorem ipsum ", 20)}</p>
        </div>
        \"\"\"
      end

      #{Enum.join(handles, "\n  ")}
    end
    """
  end
end

names = ~w(Dashboard Analytics Inbox Calendar Billing Reports Settings Search Notifications Tasks Projects Users Teams Orders Catalog SearchIndex AuditLog)

for {name, idx} <- Enum.with_index(names, 1) do
  path = Path.join(live_dir, "#{Macro.underscore(name)}_live.ex")
  content = Generator.large_live(name, idx, module_name)
  File.write!(path, content)
  IO.puts("  created #{Path.relative_to(path, dest)} (#{byte_size(content)} bytes)")
end

# Add a few extra Ecto schemas + migrations to make ecto.setup non-trivial
schemas = ~w(Post Comment Invoice Subscription Event Audit)

for schema <- schemas do
  table = Macro.underscore(schema) <> "s"

  schema_path = Path.join([dest, "lib", app_name, "#{Macro.underscore(schema)}.ex"])

  File.write!(schema_path, """
  defmodule #{module_name}.#{schema} do
    use Ecto.Schema
    import Ecto.Changeset

    schema "#{table}" do
      #{Enum.map_join(1..12, "\n      ", fn i -> "field :field_#{i}, :string" end)}
      field :count, :integer, default: 0
      field :meta, :map
      timestamps()
    end

    def changeset(struct, attrs) do
      struct
      |> cast(attrs, [#{Enum.map_join(1..12, ", ", fn i -> ":field_#{i}" end)}, :count, :meta])
      |> validate_required([:field_1])
      #{Enum.map_join(1..6, "\n    ", fn i -> "|> validate_length(:field_#{i}, max: 255)" end)}
    end
  end
  """)

  mig_ts = "2026010#{Enum.find_index(schemas, &(&1 == schema)) + 1}00000"

  mig_path =
    Path.join([dest, "priv", "repo", "migrations", "#{mig_ts}_create_#{table}.exs"])

  File.write!(mig_path, """
  defmodule #{module_name}.Repo.Migrations.Create#{schema}s do
    use Ecto.Migration

    def change do
      create table(:#{table}) do
        #{Enum.map_join(1..12, "\n        ", fn i -> "add :field_#{i}, :string" end)}
        add :count, :integer, default: 0
        add :meta, :map
        timestamps()
      end

      #{Enum.map_join(1..3, "\n    ", fn i -> "create index(:#{table}, [:field_#{i}])" end)}
    end
  end
  """)

  IO.puts("  created schema #{schema} + migration")
end

# Append router entries for all lives
router_path = Path.join([dest, "lib", "#{app_name}_web", "router.ex"])
router = File.read!(router_path)

live_routes =
  Enum.map_join(names, "\n", fn n ->
    path = "/" <> Macro.underscore(n)
    mod = "#{module_name}Web.#{n}Live"
    "      live \"#{path}\", #{mod}, :index"
  end)

router =
  String.replace(
    router,
    "scope \"/\", #{module_name}Web do",
    "scope \"/\", #{module_name}Web do\n#{live_routes}"
  )

File.write!(router_path, router)
IO.puts("  updated router with #{length(names)} live routes")

# Wire tak as a path dep so bench/profile_demo.exs can run `mix tak.create` inside demo
tak_path = Path.expand(__DIR__ |> Path.join(".."))
mix_path = Path.join(dest, "mix.exs")
mix_content = File.read!(mix_path)

if String.contains?(mix_content, "{:tak,") do
  IO.puts("  :tak already wired")
else
  mix_content =
    Regex.replace(~r/defp deps do\s*\[/, mix_content, "defp deps do\n    [{:tak, path: \"#{tak_path}\", only: :dev},\n     ")

  File.write!(mix_path, mix_content)
  IO.puts("  wired :tak path dep -> #{tak_path}")
end

# Ensure config has tak import and trees gitignore
config_path = Path.join(dest, "config/config.exs")
config = File.read!(config_path)

unless String.contains?(config, "import_config") do
  File.write!(config_path, config <> "\nif File.exists?(\"\#{__DIR__}/\#{config_env()}.local.exs\") do\n  import_config \"\#{config_env()}.local.exs\"\nend\n")
end

gitignore_path = Path.join(dest, ".gitignore")
gitignore = File.read!(gitignore_path)
extra = "/config/*.local.exs\n/mise.local.toml\n/trees/\n"

unless String.contains?(gitignore, "/trees/") do
  File.write!(gitignore_path, gitignore <> "\n" <> extra)
  IO.puts("  updated .gitignore for tak")
end

# Commit everything so `git worktree add` works (requires HEAD)
System.cmd("git", ["add", "-A"], cd: dest, stderr_to_stdout: true)
System.cmd("git", ["-c", "user.email=bench@example.com", "-c", "user.name=Bench", "commit", "-m", "initial demo commit", "-q"],
  cd: dest,
  stderr_to_stdout: true
)

case System.cmd("git", ["rev-parse", "HEAD"], cd: dest, stderr_to_stdout: true) do
  {sha, 0} -> IO.puts("  committed demo: #{String.trim(sha) |> String.slice(0, 7)}")
  _ -> IO.puts("  warning: demo not committed – `git worktree add` will fail")
end

IO.puts("\nDone. Demo app at #{dest}")
IO.puts("  LiveViews : #{length(names)} (~#{(length(names) * 650)} lines)")
IO.puts("  Schemas   : #{length(schemas)} + migrations")
IO.puts("\nNext steps:")
IO.puts("  cd #{dest} && mix deps.get && mix compile")
IO.puts("  # then benchmark from tak repo:")
IO.puts("  TAK_PROFILE=1 mix tak.create feature/bench armstrong --no-db")
IO.puts("  TAK_PROFILE=1 mix tak.create feature/bench-db hickey")
IO.puts("  mix run bench/profile_demo.exs #{dest}")
