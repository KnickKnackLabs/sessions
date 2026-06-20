select
  session_id,
  call_seq as seq,
  tool_call_id,
  command
from bash_calls
order by session_id, call_seq, tool_call_id;
