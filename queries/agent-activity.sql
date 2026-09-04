with
-- Summarize who owns the attributed sessions in the selected projection.
-- Session count is not workload, so keep assistant messages, tokens, and cost beside it.
activity as (
  select
    json_extract(meta, '$.agent.name') as agent,
    assistant_messages,
    total_tokens,
    cost_total,
    first_timestamp,
    last_timestamp
  from sessions
  where json_extract(meta, '$.agent.name') is not null
)
select
  agent,
  count(*) as sessions,
  round(100.0 * count(*) / sum(count(*)) over (), 1) as session_pct,
  sum(assistant_messages) as assistant_messages,
  sum(total_tokens) as total_tokens,
  round(sum(cost_total), 2) as cost,
  substr(min(first_timestamp), 1, 10) as first_date,
  substr(max(last_timestamp), 1, 10) as last_date
from activity
group by agent
order by sessions desc, agent;
