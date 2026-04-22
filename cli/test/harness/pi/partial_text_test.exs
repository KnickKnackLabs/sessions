defmodule Cli.Harness.Pi.PartialTextTest do
  use ExUnit.Case
  import ExUnit.CaptureIO

  # Aliased as PiStream to avoid collision with Elixir's stdlib Stream.
  alias Cli.Harness.Pi.Stream, as: PiStream

  describe "extract_partial_text/1" do
    test "extracts text from partial pi text_delta event" do
      partial =
        ~s({"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"Hello wor)

      assert PiStream.extract_partial_text(partial) == "Hello wor"
    end

    test "handles JSON escapes" do
      partial =
        ~s({"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"line1\\nline2\\ttab)

      assert PiStream.extract_partial_text(partial) == "line1\nline2\ttab"
    end

    test "returns empty string for non-delta partial" do
      partial = ~s({"type":"session","version":3,"id":"abc)
      assert PiStream.extract_partial_text(partial) == ""
    end

    test "returns empty string for non-JSON" do
      assert PiStream.extract_partial_text("random data") == ""
    end

    test "returns empty string for empty input" do
      assert PiStream.extract_partial_text("") == ""
    end
  end

  describe "flush_partial_buffer/1" do
    test "extracts and outputs text from partial pi text_delta event" do
      partial =
        ~s({"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"Hello wor)

      output = capture_io(fn -> PiStream.flush_partial_buffer(partial) end)
      assert output == "Hello wor"
    end

    test "handles JSON escapes in partial text" do
      partial =
        ~s({"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"line1\\nline2\\ttab)

      output = capture_io(fn -> PiStream.flush_partial_buffer(partial) end)
      assert output == "line1\nline2\ttab"
    end

    test "outputs nothing for partial JSON without delta field" do
      partial =
        ~s({"type":"message_update","assistantMessageEvent":{"type":"toolcall_start","contentIndex":1)

      output = capture_io(fn -> PiStream.flush_partial_buffer(partial) end)
      assert output == ""
    end

    test "outputs nothing for non-JSON partial data" do
      partial = "some random data without json structure"

      output = capture_io(fn -> PiStream.flush_partial_buffer(partial) end)
      assert output == ""
    end

    test "outputs nothing for empty string" do
      output = capture_io(fn -> PiStream.flush_partial_buffer("") end)
      assert output == ""
    end
  end
end
