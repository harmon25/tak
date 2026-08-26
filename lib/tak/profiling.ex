defmodule Tak.Profiling do
  @moduledoc false
  # Gated profiling for `tak.create`. No overhead when disabled.
  # Enabled via `--profile` flag or `TAK_PROFILE=1` env.

  def enabled?(opts) do
    Keyword.get(opts, :profile, false) or env_enabled?()
  end

  def env_enabled? do
    case System.get_env("TAK_PROFILE") do
      v when v in ["1", "true", "TRUE", "yes"] -> true
      _ -> Application.get_env(:tak, :profile, false) == true
    end
  end

  def start do
    %{timings: [], total_start: System.monotonic_time(:millisecond)}
  end

  def measure(%{timings: timings} = state, label, fun) do
    t0 = System.monotonic_time(:millisecond)
    result = fun.()
    elapsed = System.monotonic_time(:millisecond) - t0
    new_state = %{state | timings: [{label, elapsed} | timings]}
    {result, new_state}
  end

  def finish(%{timings: timings, total_start: t0}) do
    total = System.monotonic_time(:millisecond) - t0
    ordered = Enum.reverse(timings)
    {ordered, total}
  end

  def format_report(timings, total) do
    rows =
      Enum.map(timings, fn {label, ms} ->
        pct = if total > 0, do: Float.round(ms / total * 100, 1), else: 0.0
        "  #{String.pad_trailing(label, 22)} #{String.pad_leading("#{ms}ms", 8)}  (#{pct}%)"
      end)

    header = "[TAK PROFILE] breakdown (total #{total}ms):"

    Enum.join(
      [header | rows] ++
        ["  #{String.pad_trailing("total", 22)} #{String.pad_leading("#{total}ms", 8)}"],
      "\n"
    )
  end

  def report(timings, total) do
    Mix.shell().info(format_report(timings, total))
  end

  # Convenience for one-off wrapping outside create flow (e.g. System.cmd)
  def timed(label, fun) do
    t0 = System.monotonic_time(:millisecond)
    result = fun.()
    elapsed = System.monotonic_time(:millisecond) - t0
    {result, elapsed, label}
  end
end
