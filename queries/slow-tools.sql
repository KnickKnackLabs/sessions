select
  session_id,
  tool_name,
  command_category,
  count(*) as calls,
  round(avg(duration_ms) / 1000.0, 3) as avg_s,
  round(max(duration_ms) / 1000.0, 3) as max_s,
  sum(case when is_error = 1 then 1 else 0 end) as errors
from tool_pairs
where duration_ms is not null
group by session_id, tool_name, command_category
order by max(duration_ms) desc
limit 100;
