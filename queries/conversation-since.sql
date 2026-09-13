with
-- Run over exactly one known session with --text compact or --text full.
-- Copy this file before editing params: after_seq is an exclusive JSONL line
-- checkpoint from this same session (0 starts at the beginning). message_count
-- is a positive row limit, or NULL for all. Continue from the last returned seq.
-- Return the earliest nonblank user/assistant text rows after the checkpoint.
-- This is recorded history, including abandoned branches, not the active leaf.
-- Zero/multiple projected sessions or text modes none/commands return no rows.
params(after_seq, message_count) as (values (0, 20))
select session_id, seq, timestamp, role, text_chars, text_excerpt as text
from messages
where (select count(*) from sessions) = 1
  and seq > (select after_seq from params)
  and role in ('user', 'assistant')
  and length(trim(text_excerpt, char(9, 10, 11, 12, 13, 32))) > 0
order by seq
limit coalesce((select message_count from params), -1);
