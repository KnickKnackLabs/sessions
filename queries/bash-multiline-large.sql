with shaped as (
  select
    session_id,
    call_seq,
    tool_call_id,
    command_category,
    length(command) as chars,
    1 + length(command) - length(replace(command, char(10), '')) as lines,
    round(duration_ms / 1000.0, 3) as duration_s,
    exit_status,
    is_error,
    output_lines,
    command
  from bash_calls
  where command is not null
)
select
  session_id,
  call_seq,
  tool_call_id,
  command_category,
  chars,
  lines,
  duration_s,
  exit_status,
  is_error,
  output_lines,
  command
from shaped
where lines >= 8 or chars >= 500
order by chars desc, lines desc, session_id, call_seq;
