with
-- Triage unmatched tool calls and results without calling them corruption.
-- Earlier entries can come from branches or historical transcript shapes.
latest_calls as (
  select session_id, max(call_seq) as call_seq
  from tool_pairs
  group by session_id
), issues as (
  select
    'unpaired call' as issue,
    case
      when p.call_seq = latest_calls.call_seq then 'latest call entry'
      else 'earlier entry'
    end as position,
    p.tool_name,
    p.command_category
  from tool_pairs p
  join latest_calls using (session_id)
  where p.result_seq is null

  union all

  select
    'orphan result' as issue,
    'unknown' as position,
    r.tool_name,
    null as command_category
  from tool_results r
  left join tool_calls c
    on c.session_id = r.session_id
   and c.tool_call_id = r.tool_call_id
  where c.tool_call_id is null
)
select
  issue,
  position,
  tool_name,
  command_category,
  count(*) as rows
from issues
group by issue, position, tool_name, command_category
order by issue, rows desc, position, tool_name, command_category;
