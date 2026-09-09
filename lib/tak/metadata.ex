defmodule Tak.Metadata do
  @moduledoc false

  @filename ".tak"

  @doc """
  Writes worktree metadata as an Elixir term file.
  """
  def write!(%Tak.Worktree{} = worktree) do
    data = %{
      name: worktree.name,
      branch: worktree.branch,
      port: worktree.port,
      database: worktree.database,
      database_managed?: worktree.database_managed?
    }

    content = "#{inspect(data, pretty: true, limit: :infinity)}\n"
    File.write!(path(worktree.path), content)
  end

  @doc """
  Reads worktree metadata from the `.tak` file, returning a `Tak.Worktree` struct
  or `nil` if the file doesn't exist or can't be parsed.
  """
  def read(worktree_path) do
    file = path(worktree_path)

    if File.exists?(file) do
      with {:ok, content} <- File.read(file),
           {%{} = data, _} <- safe_decode(content),
           :ok <- validate_data(data) do
        %Tak.Worktree{
          name: data[:name],
          branch: data[:branch],
          port: data[:port],
          path: worktree_path,
          database: data[:database],
          database_managed?: data[:database_managed?]
        }
      else
        _ -> nil
      end
    end
  end

  # Parses the metadata as an Elixir term without executing arbitrary code.
  # Only allows literals (maps, strings, integers, booleans, nil, atoms).
  defp safe_decode(content) do
    case Code.string_to_quoted(content) do
      {:ok, ast} ->
        if safe_ast?(ast) do
          {result, _} = Code.eval_quoted(ast)
          {result, []}
        else
          nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp safe_ast?({:%{}, _, pairs}) when is_list(pairs) do
    Enum.all?(pairs, fn {k, v} -> safe_ast?(k) and safe_ast?(v) end)
  end

  defp safe_ast?(val) when is_atom(val), do: true
  defp safe_ast?(val) when is_binary(val), do: true
  defp safe_ast?(val) when is_integer(val), do: true
  defp safe_ast?(val) when is_float(val), do: true
  defp safe_ast?({val, _, nil}) when is_atom(val), do: true
  defp safe_ast?(_), do: false

  defp validate_data(data) do
    cond do
      not is_binary(data[:name]) -> :error
      not (is_binary(data[:branch]) or is_nil(data[:branch])) -> :error
      not (is_integer(data[:port]) or is_nil(data[:port])) -> :error
      not (is_binary(data[:database]) or is_nil(data[:database])) -> :error
      not is_boolean(data[:database_managed?]) -> :error
      true -> :ok
    end
  end

  defp path(worktree_path), do: Path.join(worktree_path, @filename)
end
