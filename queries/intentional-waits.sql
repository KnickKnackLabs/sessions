with
-- Find long-running calls that look like deliberate waits or watchers.
-- These are command-shape heuristics; inspect and tune them for your environment.
classified as (
  select
    session_id,
    call_seq,
    tool_call_id,
    tool_name,
    command_category,
    duration_ms,
    exit_status,
    is_error,
    command,
    case
      when lower(coalesce(command, '')) like '%chat wait%'
      then 'chat wait'
      when lower(coalesce(command, '')) like '%sessions wait-any%'
        or lower(coalesce(command, '')) like '%sessions wait %'
      then 'sessions wait'
      when lower(coalesce(command, '')) like '%shell wait%'
      then 'shell wait'
      when lower(coalesce(command, '')) like '%gh run watch%'
      then 'CI watch'
      when lower(coalesce(command, '')) like '%foreman%'
       and (
         lower(command) like '%watch%'
         or lower(command) like '%wait%'
       )
      then 'foreman watcher'
      when lower(coalesce(command, '')) like '%--forever%'
      then 'forever flag'
      when lower(coalesce(command, '')) glob 'sleep *'
        or lower(coalesce(command, '')) like '%; sleep %'
      then 'sleep'
      else null
    end as wait_kind
  from tool_pairs
  where duration_ms is not null
)
select
  wait_kind,
  session_id,
  call_seq,
  tool_call_id,
  tool_name,
  command_category,
  round(duration_ms / 1000.0, 2) as seconds,
  exit_status,
  is_error,
  command
from classified
where wait_kind is not null
order by duration_ms desc, session_id, call_seq
limit 200;
