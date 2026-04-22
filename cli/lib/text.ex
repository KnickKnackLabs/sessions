defmodule Cli.Text do
  @moduledoc """
  Harness-agnostic text-stream helpers used by the `sessions run` engine.

  These operate purely on strings — no knowledge of any specific harness
  schema — so every harness adapter can call them directly instead of
  receiving them as callbacks. Moving them here breaks the circular
  dependency that would otherwise exist between `Cli` and the harness
  stream parsers (`Cli.Harness.Pi.Stream` today, plus any future
  adapter).
  """

  @doc """
  Return the portion of `text` beyond already-flushed characters.

  ## Examples

      iex> Cli.Text.text_beyond_flushed("hello world", 5)
      " world"

      iex> Cli.Text.text_beyond_flushed("hello", 5)
      ""

      iex> Cli.Text.text_beyond_flushed("hello", 0)
      "hello"

      iex> Cli.Text.text_beyond_flushed("hi", 10)
      ""

  """
  @spec text_beyond_flushed(String.t(), non_neg_integer()) :: String.t()
  def text_beyond_flushed(text, 0), do: text

  def text_beyond_flushed(text, flushed_chars) when is_integer(flushed_chars) do
    if String.length(text) > flushed_chars do
      String.slice(text, flushed_chars..-1//1)
    else
      ""
    end
  end

  @typep abort_state :: %{
           abort_seen: boolean(),
           recent_text: String.t(),
           had_newline_before_window: boolean()
         }

  @doc """
  Detect `[[ABORT]]` on its own line across streaming chunks.

  Returns `{abort_seen, recent_text, had_newline_before_window}`:

    * `abort_seen` stays `true` once set.
    * `recent_text` is the last 20 characters of combined input, kept
      for boundary-spanning detection.
    * `had_newline_before_window` remembers whether a newline has
      already been observed outside the current 20-char lookback window.
  """
  @spec check_abort_signal(String.t(), abort_state()) ::
          {boolean(), String.t(), boolean()}
  def check_abort_signal(text, state) do
    combined = state.recent_text <> text
    combined_len = String.length(combined)

    trimmed_len = max(0, combined_len - 20)
    trimmed_portion = String.slice(combined, 0, trimmed_len)

    had_newline_before_window =
      if String.contains?(trimmed_portion, "\n"),
        do: true,
        else: state.had_newline_before_window

    text_to_check =
      if had_newline_before_window, do: "\n" <> combined, else: combined

    abort_seen =
      state.abort_seen ||
        Regex.match?(~r/(?:^|\n)\[\[ABORT\]\](?:\n|$)/, text_to_check)

    recent_text = String.slice(combined, -20, 20)

    {abort_seen, recent_text, had_newline_before_window}
  end
end
