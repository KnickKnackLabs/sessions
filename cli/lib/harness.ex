defmodule Cli.Harness do
  @moduledoc """
  Harness dispatch layer (Elixir). Mirrors `lib/harness/dispatch.sh` and
  `lib/harness/__init__.py`.

  Resolves which harness adapter a session uses and returns the adapter
  module. Step 2 of sessions#50.

  Resolver priority (highest first):
    1. Explicit `:name` option (caller already knows)
    2. Most recent `{"type": "harness"}` entry in the session JSONL
    3. Path-based detection (session file under `~/.pi/...` → pi)
    4. `$SESSIONS_DEFAULT_HARNESS` environment variable
    5. Compile-time default: `:pi`

  Each adapter module exposes the public API the engine uses
  (`build_command/6`, `default_model/0`, `process_line/2`,
  `extract_partial_text/1`). See `Cli.Harness.Pi` for the reference.
  """

  @default :pi
  @adapters %{pi: Cli.Harness.Pi}

  @spec available() :: [atom()]
  def available, do: @adapters |> Map.keys() |> Enum.sort()

  @spec default() :: atom()
  def default, do: @default

  @spec adapter(atom()) :: module()
  def adapter(name) when is_atom(name) do
    case Map.fetch(@adapters, name) do
      {:ok, mod} -> mod
      :error -> raise ArgumentError, "Unknown harness: #{inspect(name)} (available: #{inspect(available())})"
    end
  end

  @doc """
  Resolve the harness adapter for a session.

  Options:
    * `:name` — explicit harness name (atom), short-circuits the resolver
    * `:session` — path to a session JSONL file; used for rules 2 and 3
  """
  @spec resolve(keyword()) :: module()
  def resolve(opts \\ []) do
    explicit =
      case opts[:name] do
        nil -> nil
        atom when is_atom(atom) -> atom
        str when is_binary(str) -> atomize_or_raise(str, "name: option")
      end

    name =
      explicit
      |> maybe_or(fn -> from_session_file(opts[:session]) end)
      |> maybe_or(fn -> from_path(opts[:session]) end)
      |> maybe_or(&from_env/0)
      |> maybe_or(fn -> @default end)

    adapter(name)
  end

  # --- Internals ---

  defp maybe_or(nil, fun), do: fun.()
  defp maybe_or(value, _fun), do: value

  defp from_session_file(nil), do: nil

  defp from_session_file(path) do
    case File.read(path) do
      {:ok, body} ->
        body
        |> String.split("\n", trim: true)
        |> Enum.reverse()
        |> Enum.find_value(&extract_harness_name/1)

      _ ->
        nil
    end
  end

  defp extract_harness_name(line) do
    case Jason.decode(line) do
      {:ok, %{"type" => "harness", "name" => name}} when is_binary(name) ->
        atomize_or_raise(name, "session file")

      _ ->
        nil
    end
  end

  defp from_path(nil), do: nil

  # Infer the harness from a path prefix. Kept in sync with
  # `lib/harness/dispatch.sh` and `lib/harness/__init__.py` — review all
  # three together when editing.
  #
  # Each prefix candidate ends with a `/` so `~/.pi-alt/...` does not
  # get claimed by the pi adapter. Both `$PI_DIR` and the literal
  # `$HOME/.pi` path are checked, because the environment override and
  # the default location can coexist (e.g. a user with a custom PI_DIR
  # who still has legacy sessions under ~/.pi).
  defp from_path(path) when is_binary(path) do
    home = System.get_env("HOME")
    home_pi = if home, do: Path.join(home, ".pi/"), else: nil
    env_pi = System.get_env("PI_DIR")
    env_pi_slash = if env_pi, do: String.trim_trailing(env_pi, "/") <> "/", else: nil

    candidates =
      [env_pi_slash, home_pi]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    cond do
      Enum.any?(candidates, &String.starts_with?(path, &1)) -> :pi
      true -> nil
    end
  end

  defp from_env do
    case System.get_env("SESSIONS_DEFAULT_HARNESS") do
      nil -> nil
      "" -> nil
      name -> atomize_or_raise(name, "$SESSIONS_DEFAULT_HARNESS")
    end
  end

  # Convert a string harness name to a known-adapter atom, raising with
  # a source-aware message if the name is not a registered adapter.
  #
  # We explicitly do NOT use `String.to_atom/1` — that would be an
  # atom-exhaustion vector, since names can come from user-controlled
  # environment variables and (eventually) session files.
  defp atomize_or_raise(name, source) when is_binary(name) do
    match =
      Enum.find(Map.keys(@adapters), fn atom -> Atom.to_string(atom) == name end)

    case match do
      nil ->
        raise ArgumentError,
              "Unknown harness #{inspect(name)} from #{source} " <>
                "(available: #{inspect(available())})"

      atom ->
        atom
    end
  end
end
