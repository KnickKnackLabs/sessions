select
  session_id,
  call_seq as seq,
  tool_call_id,
  command_category,
  exit_status,
  round(duration_ms / 1000.0, 3) as duration_s,
  output_lines,
  output_bytes,
  command,
  output_excerpt
from bash_calls
where is_error = 1 or coalesce(exit_status, 0) != 0
order by session_id, call_seq, tool_call_id;
