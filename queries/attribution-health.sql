select
  -- Show whether metadata can support agent-level comparisons over time.
  coalesce(substr(first_timestamp, 1, 7), '<unknown>') as month,
  count(*) as sessions,
  sum(
    case
      when json_extract(meta, '$.agent.name') is not null
      then 1 else 0
    end
  ) as attributed_sessions,
  sum(
    case
      when json_extract(meta, '$.agent.name') is null
      then 1 else 0
    end
  ) as unattributed_sessions,
  round(
    100.0 * sum(
      case
        when json_extract(meta, '$.agent.name') is not null
        then 1 else 0
      end
    ) / count(*),
    1
  ) as attributed_pct,
  sum(assistant_messages) as assistant_messages,
  sum(total_tokens) as total_tokens,
  round(sum(cost_total), 2) as cost
from sessions
group by month
order by month;
