with
-- Run over exactly one known session with --text compact or --text full.
-- Copy this file before editing params: positive message_count, or NULL for all.
-- Select newest nonblank assistant text rows, then display in recorded order.
-- seq is a JSONL line number, not a turn or an active-branch position. This
-- includes abandoned branches and text accompanying tool calls, not just finals.
-- Zero/multiple projected sessions or text modes none/commands return no rows.
params(message_count) as (values (1)),
latest as (
  select session_id, seq, timestamp, role, text_chars, text_excerpt as text
  from messages
  where (select count(*) from sessions) = 1
    and role = 'assistant'
    and length(trim(text_excerpt, char(9, 10, 11, 12, 13, 32))) > 0
  order by seq desc
  limit coalesce((select message_count from params), -1)
)
select * from latest
order by seq;
