with
-- Compare attributed work by active UTC day and inferred settled control segment.
-- Query does not project Pi stopReason yet, so an assistant entry with no tool call
-- is an approximation of the Pi adapter's exact segment-settlement rule.
assistant_activity as (
  select
    s.session_id,
    json_extract(s.meta, '$.agent.name') as agent,
    date(m.timestamp) as active_day_utc,
    case
      when not exists (
        select 1
        from tool_calls c
        where c.session_id = m.session_id
          and c.seq = m.seq
      )
      then 1 else 0
    end as inferred_settled
  from sessions s
  join messages m using (session_id)
  where m.role = 'assistant'
    and json_extract(s.meta, '$.agent.name') is not null
)
select
  agent,
  count(distinct session_id) as sessions,
  count(distinct active_day_utc) as active_days_utc,
  sum(inferred_settled) as inferred_settled_segments,
  count(*) as assistant_messages,
  round(
    1.0 * count(*) / nullif(sum(inferred_settled), 0),
    1
  ) as assistant_messages_per_segment,
  round(
    1.0 * sum(inferred_settled) / nullif(count(distinct active_day_utc), 0),
    1
  ) as segments_per_active_day
from assistant_activity
group by agent
order by inferred_settled_segments desc, agent;
