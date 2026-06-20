select
  session_id,
  call_seq as seq,
  tool_call_id,
  command_category,
  exit_status,
  is_error,
  round(duration_ms / 1000.0, 3) as duration_s,
  output_lines,
  output_bytes,
  command
from bash_calls
order by session_id, call_seq, tool_call_id;
