defmodule Cli.Harness.Pi.StreamTest do
  use ExUnit.Case
  import ExUnit.CaptureIO

  # Aliased as PiStream to avoid collision with Elixir's stdlib Stream.
  alias Cli.Harness.Pi.Stream, as: PiStream

  describe "process_line/2 — pi text events" do
    test "outputs text delta and tracks abort_seen" do
      line =
        Jason.encode!(%{
          "type" => "message_update",
          "assistantMessageEvent" => %{"type" => "text_delta", "delta" => "Hello"}
        })

      state = %{
        tool_input: "",
        abort_seen: false,
        recent_text: "",
        flushed_chars: 0,
        had_newline_before_window: true
      }

      output =
        capture_io(fn ->
          result = PiStream.process_line(line, state)
          send(self(), {:result, result})
        end)

      assert output == "Hello"

      assert_received {:result,
                       %{
                         tool_input: "",
                         abort_seen: false,
                         recent_text: "Hello",
                         flushed_chars: 0
                       }}
    end

    test "detects [[ABORT]] on its own line" do
      line =
        Jason.encode!(%{
          "type" => "message_update",
          "assistantMessageEvent" => %{"type" => "text_delta", "delta" => "[[ABORT]]\n"}
        })

      state = %{
        tool_input: "",
        abort_seen: false,
        recent_text: "",
        flushed_chars: 0,
        had_newline_before_window: true
      }

      capture_io(fn ->
        result = PiStream.process_line(line, state)
        send(self(), {:result, result})
      end)

      assert_received {:result, %{abort_seen: true}}
    end

    test "detects [[ABORT]] split across streaming chunks" do
      line1 =
        Jason.encode!(%{
          "type" => "message_update",
          "assistantMessageEvent" => %{"type" => "text_delta", "delta" => "[[ABO"}
        })

      state1 = %{
        tool_input: "",
        abort_seen: false,
        recent_text: "",
        flushed_chars: 0,
        had_newline_before_window: true
      }

      capture_io(fn ->
        result = PiStream.process_line(line1, state1)
        send(self(), {:result1, result})
      end)

      assert_received {:result1, %{abort_seen: false} = state2}

      line2 =
        Jason.encode!(%{
          "type" => "message_update",
          "assistantMessageEvent" => %{"type" => "text_delta", "delta" => "RT]]\n"}
        })

      capture_io(fn ->
        result = PiStream.process_line(line2, state2)
        send(self(), {:result2, result})
      end)

      assert_received {:result2, %{abort_seen: true}}
    end

    test "detects [[ABORT]] split across chunks when followed by long text" do
      line1 =
        Jason.encode!(%{
          "type" => "message_update",
          "assistantMessageEvent" => %{"type" => "text_delta", "delta" => "prefix\n[[ABO"}
        })

      state1 = %{
        tool_input: "",
        abort_seen: false,
        recent_text: "",
        flushed_chars: 0,
        had_newline_before_window: true
      }

      capture_io(fn ->
        result = PiStream.process_line(line1, state1)
        send(self(), {:result1, result})
      end)

      assert_received {:result1, %{abort_seen: false} = state2}

      line2 =
        Jason.encode!(%{
          "type" => "message_update",
          "assistantMessageEvent" => %{
            "type" => "text_delta",
            "delta" => "RT]]\nlots of additional text that pushes it out of window"
          }
        })

      capture_io(fn ->
        result = PiStream.process_line(line2, state2)
        send(self(), {:result2, result})
      end)

      assert_received {:result2, %{abort_seen: true}}
    end

    test "detects [[ABORT]] after >20 chars of text ending with newline" do
      line1 =
        Jason.encode!(%{
          "type" => "message_update",
          "assistantMessageEvent" => %{
            "type" => "text_delta",
            "delta" => "aaaaaaaaaaaaaaaaaaaaaaa\n"
          }
        })

      state1 = %{
        tool_input: "",
        abort_seen: false,
        recent_text: "",
        flushed_chars: 0,
        had_newline_before_window: true
      }

      capture_io(fn ->
        result = PiStream.process_line(line1, state1)
        send(self(), {:result1, result})
      end)

      assert_received {:result1, %{abort_seen: false} = state2}

      line2 =
        Jason.encode!(%{
          "type" => "message_update",
          "assistantMessageEvent" => %{"type" => "text_delta", "delta" => "[[ABORT]]\n"}
        })

      capture_io(fn ->
        result = PiStream.process_line(line2, state2)
        send(self(), {:result2, result})
      end)

      assert_received {:result2, %{abort_seen: true}}
    end

    test "does not detect [[ABORT]] embedded in text" do
      line =
        Jason.encode!(%{
          "type" => "message_update",
          "assistantMessageEvent" => %{
            "type" => "text_delta",
            "delta" => "some [[ABORT]] text"
          }
        })

      state = %{
        tool_input: "",
        abort_seen: false,
        recent_text: "",
        flushed_chars: 0,
        had_newline_before_window: true
      }

      capture_io(fn ->
        result = PiStream.process_line(line, state)
        send(self(), {:result, result})
      end)

      assert_received {:result, %{abort_seen: false}}
    end

    test "skips already-flushed text prefix" do
      line =
        Jason.encode!(%{
          "type" => "message_update",
          "assistantMessageEvent" => %{"type" => "text_delta", "delta" => "Hello world"}
        })

      state = %{
        tool_input: "",
        abort_seen: false,
        recent_text: "",
        flushed_chars: 9,
        had_newline_before_window: true
      }

      output =
        capture_io(fn ->
          result = PiStream.process_line(line, state)
          send(self(), {:result, result})
        end)

      assert output == "ld"
      assert_received {:result, %{flushed_chars: 0}}
    end

    test "outputs full text when flushed_chars is zero" do
      line =
        Jason.encode!(%{
          "type" => "message_update",
          "assistantMessageEvent" => %{"type" => "text_delta", "delta" => "Hello world"}
        })

      state = %{
        tool_input: "",
        abort_seen: false,
        recent_text: "",
        flushed_chars: 0,
        had_newline_before_window: true
      }

      output =
        capture_io(fn ->
          result = PiStream.process_line(line, state)
          send(self(), {:result, result})
        end)

      assert output == "Hello world"
    end

    test "outputs remaining text when flushed_chars exceeds text length" do
      line =
        Jason.encode!(%{
          "type" => "message_update",
          "assistantMessageEvent" => %{"type" => "text_delta", "delta" => "Hi"}
        })

      state = %{
        tool_input: "",
        abort_seen: false,
        recent_text: "",
        flushed_chars: 10,
        had_newline_before_window: true
      }

      output =
        capture_io(fn ->
          result = PiStream.process_line(line, state)
          send(self(), {:result, result})
        end)

      assert output == ""
    end
  end

  describe "process_line/2 — pi tool events" do
    test "resets tool_input on toolcall_start and prints tool name" do
      line =
        Jason.encode!(%{
          "type" => "message_update",
          "assistantMessageEvent" => %{
            "type" => "toolcall_start",
            "contentIndex" => 1,
            "partial" => %{
              "content" => [
                %{"type" => "text", "text" => "I'll run that."},
                %{"type" => "toolCall", "name" => "bash", "arguments" => %{}}
              ]
            }
          }
        })

      state = %{tool_input: "leftover"}

      output =
        capture_io(fn ->
          result = PiStream.process_line(line, state)
          send(self(), {:result, result})
        end)

      assert output =~ "[TOOL] bash"
      assert_received {:result, %{tool_input: ""}}
    end

    test "accumulates toolcall_delta to tool_input" do
      line =
        Jason.encode!(%{
          "type" => "message_update",
          "assistantMessageEvent" => %{
            "type" => "toolcall_delta",
            "delta" => ~s({"command": "ls)
          }
        })

      state = %{tool_input: ""}
      result = PiStream.process_line(line, state)
      assert result.tool_input == ~s({"command": "ls)
    end

    test "ignores empty toolcall_delta" do
      line =
        Jason.encode!(%{
          "type" => "message_update",
          "assistantMessageEvent" => %{
            "type" => "toolcall_delta",
            "delta" => ""
          }
        })

      state = %{tool_input: "existing"}
      result = PiStream.process_line(line, state)
      assert result.tool_input == "existing"
    end

    test "appends toolcall_delta to existing tool_input" do
      line =
        Jason.encode!(%{
          "type" => "message_update",
          "assistantMessageEvent" => %{
            "type" => "toolcall_delta",
            "delta" => ~s( -la"})
          }
        })

      state = %{tool_input: ~s({"command": "ls)}
      result = PiStream.process_line(line, state)
      assert result.tool_input == ~s({"command": "ls -la"})
    end

    test "clears tool_input on toolcall_end and prints formatted output" do
      line =
        Jason.encode!(%{
          "type" => "message_update",
          "assistantMessageEvent" => %{
            "type" => "toolcall_end",
            "toolCall" => %{
              "name" => "bash",
              "arguments" => %{"command" => "ls -la"}
            }
          }
        })

      state = %{tool_input: ~s({"command":"ls -la"})}

      output =
        capture_io(fn ->
          result = PiStream.process_line(line, state)
          send(self(), {:result, result})
        end)

      assert output =~ "$ ls -la"
      assert_received {:result, %{tool_input: ""}}
    end

    test "handles toolcall_end with no arguments" do
      line =
        Jason.encode!(%{
          "type" => "message_update",
          "assistantMessageEvent" => %{
            "type" => "toolcall_end",
            "toolCall" => %{"name" => "bash"}
          }
        })

      state = %{tool_input: ""}

      output =
        capture_io(fn ->
          result = PiStream.process_line(line, state)
          send(self(), {:result, result})
        end)

      assert output == ""
      assert_received {:result, %{tool_input: ""}}
    end
  end

  describe "process_line/2 — pi agent_end" do
    test "extracts usage data from agent_end event" do
      line =
        Jason.encode!(%{
          "type" => "agent_end",
          "messages" => [
            %{"role" => "user", "content" => [%{"type" => "text", "text" => "hello"}]},
            %{
              "role" => "assistant",
              "content" => [%{"type" => "text", "text" => "Hi!"}],
              "usage" => %{
                "input" => 100,
                "output" => 50,
                "cacheRead" => 200,
                "cacheWrite" => 300,
                "cost" => %{"total" => 0.0259}
              }
            }
          ]
        })

      state = %{tool_input: "", usage: nil}
      result_state = PiStream.process_line(line, state)

      assert result_state.usage.cost_usd == 0.0259
      assert result_state.usage.num_turns == 1
      assert result_state.usage.usage["input_tokens"] == 100
      assert result_state.usage.usage["output_tokens"] == 50
      assert result_state.usage.usage["cache_read_input_tokens"] == 200
      assert result_state.usage.usage["cache_creation_input_tokens"] == 300
    end

    test "sums usage across multiple assistant messages" do
      line =
        Jason.encode!(%{
          "type" => "agent_end",
          "messages" => [
            %{"role" => "user", "content" => []},
            %{
              "role" => "assistant",
              "usage" => %{
                "input" => 100,
                "output" => 50,
                "cacheRead" => 200,
                "cacheWrite" => 0,
                "cost" => %{"total" => 0.01}
              }
            },
            %{"role" => "toolResult", "content" => []},
            %{
              "role" => "assistant",
              "usage" => %{
                "input" => 80,
                "output" => 30,
                "cacheRead" => 250,
                "cacheWrite" => 100,
                "cost" => %{"total" => 0.005}
              }
            }
          ]
        })

      state = %{tool_input: "", usage: nil}
      result_state = PiStream.process_line(line, state)

      assert result_state.usage.cost_usd == 0.015
      assert result_state.usage.num_turns == 2
      assert result_state.usage.usage["input_tokens"] == 180
      assert result_state.usage.usage["output_tokens"] == 80
      assert result_state.usage.usage["cache_read_input_tokens"] == 450
      assert result_state.usage.usage["cache_creation_input_tokens"] == 100
    end

    test "maps assistant stopReason=error into generic agent_error state" do
      line =
        Jason.encode!(%{
          "type" => "agent_end",
          "messages" => [
            %{
              "role" => "assistant",
              "stopReason" => "error",
              "errorMessage" => "You're out of extra usage.",
              "usage" => %{
                "input" => 0,
                "output" => 0,
                "cacheRead" => 0,
                "cacheWrite" => 0,
                "cost" => %{"total" => 0.0}
              }
            }
          ]
        })

      state = %{tool_input: "", usage: nil, agent_error: nil}
      result_state = PiStream.process_line(line, state)

      assert result_state.agent_error == %{
               source: :pi,
               reason: "error",
               message: "You're out of extra usage."
             }

      assert result_state.usage.num_turns == 1
      assert result_state.usage.usage["input_tokens"] == 0
      assert result_state.usage.usage["output_tokens"] == 0
    end

    test "maps stopReason=error without errorMessage into generic agent_error state" do
      line =
        Jason.encode!(%{
          "type" => "agent_end",
          "messages" => [
            %{"role" => "assistant", "stopReason" => "error", "usage" => %{}}
          ]
        })

      state = %{tool_input: "", usage: nil, agent_error: nil}
      result_state = PiStream.process_line(line, state)

      assert result_state.agent_error == %{
               source: :pi,
               reason: "error",
               message: "assistant turn ended with stopReason=error"
             }
    end

    test "does not set agent_error for successful assistant stopReason" do
      line =
        Jason.encode!(%{
          "type" => "agent_end",
          "messages" => [
            %{"role" => "assistant", "stopReason" => "stop", "usage" => %{}}
          ]
        })

      state = %{tool_input: "", usage: nil, agent_error: nil}
      result_state = PiStream.process_line(line, state)

      assert result_state.agent_error == nil
    end
  end

  describe "process_line/2 — general" do
    test "returns state unchanged for unknown event types" do
      line = ~s({"type":"unknown"})
      state = %{tool_input: "preserved"}

      assert PiStream.process_line(line, state) == state
    end

    test "returns state unchanged for invalid JSON" do
      line = "not valid json at all"
      state = %{tool_input: "preserved"}

      assert PiStream.process_line(line, state) == state
    end

    test "returns state unchanged for empty line" do
      line = ""
      state = %{tool_input: "preserved"}

      assert PiStream.process_line(line, state) == state
    end

    test "ignores pi session/turn/message_start events" do
      for type <- ["session", "agent_start", "turn_start", "turn_end"] do
        line = Jason.encode!(%{"type" => type})
        state = %{tool_input: "preserved"}
        assert PiStream.process_line(line, state) == state
      end
    end
  end
end
