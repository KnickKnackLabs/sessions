with shaped as (
  select
    session_id,
    call_seq,
    tool_call_id,
    command_category,
    length(command) as chars,
    1 + length(command) - length(replace(command, char(10), '')) as lines,
    output_lines,
    output_bytes,
    round(duration_ms / 1000.0, 3) as duration_s,
    exit_status,
    is_error,
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
  case when lines = 1 then 'single-line' else 'multi-line' end as shape,
  duration_s,
  exit_status,
  is_error,
  output_lines,
  output_bytes,
  command
from shaped
order by chars desc, lines desc, session_id, call_seq;
