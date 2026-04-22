defmodule Cli.TextTest do
  use ExUnit.Case
  doctest Cli.Text

  describe "check_abort_signal/2" do
    test "detects abort on its own line" do
      state = %{abort_seen: false, recent_text: "", had_newline_before_window: true}
      {abort_seen, _, _} = Cli.Text.check_abort_signal("[[ABORT]]\n", state)
      assert abort_seen
    end

    test "does not detect abort embedded in text" do
      state = %{abort_seen: false, recent_text: "", had_newline_before_window: true}
      {abort_seen, _, _} = Cli.Text.check_abort_signal("some [[ABORT]] text", state)
      refute abort_seen
    end

    test "detects abort split across calls" do
      state = %{abort_seen: false, recent_text: "", had_newline_before_window: true}
      {abort_seen1, recent1, had_nl1} = Cli.Text.check_abort_signal("[[ABO", state)
      refute abort_seen1

      state2 = %{abort_seen: false, recent_text: recent1, had_newline_before_window: had_nl1}
      {abort_seen2, _, _} = Cli.Text.check_abort_signal("RT]]\n", state2)
      assert abort_seen2
    end

    test "preserves abort_seen once set" do
      state = %{abort_seen: true, recent_text: "", had_newline_before_window: true}
      {abort_seen, _, _} = Cli.Text.check_abort_signal("more text", state)
      assert abort_seen
    end

    test "tracks newline in trimmed text for boundary detection" do
      state = %{abort_seen: false, recent_text: "", had_newline_before_window: false}
      # Newline at position 5, then 30+ more chars. The 20-char window keeps the
      # last 20 chars, so the newline falls in the trimmed portion (positions 0-15+).
      long_text = String.duplicate("a", 5) <> "\n" <> String.duplicate("b", 30)
      {_, _, had_newline} = Cli.Text.check_abort_signal(long_text, state)
      assert had_newline
    end
  end

  describe "text_beyond_flushed/2" do
    test "returns remainder after flushed chars" do
      assert Cli.Text.text_beyond_flushed("hello world", 5) == " world"
    end

    test "returns empty string when fully flushed" do
      assert Cli.Text.text_beyond_flushed("hello", 5) == ""
    end

    test "returns full text when flushed_chars is zero" do
      assert Cli.Text.text_beyond_flushed("hello", 0) == "hello"
    end

    test "returns empty string when flushed_chars exceeds text length" do
      assert Cli.Text.text_beyond_flushed("different", 10) == ""
    end

    test "handles empty text" do
      assert Cli.Text.text_beyond_flushed("", 0) == ""
      assert Cli.Text.text_beyond_flushed("", 5) == ""
    end

    test "raises on nil flushed_chars (type safety)" do
      assert_raise FunctionClauseError, fn ->
        Cli.Text.text_beyond_flushed("hello world", nil)
      end
    end
  end
end
