with
-- Describe what follows a failed Bash call.
-- The next Bash call is a structural successor, not proof that it caused recovery.
ordered as (
  select
    session_id,
    call_seq,
    tool_call_id,
    command_category,
    command,
    is_error,
    exit_status,
    lead(command) over (
      partition by session_id
      order by call_seq, tool_call_id
    ) as next_command,
    lead(command_category) over (
      partition by session_id
      order by call_seq, tool_call_id
    ) as next_category,
    lead(is_error) over (
      partition by session_id
      order by call_seq, tool_call_id
    ) as next_is_error,
    lead(exit_status) over (
      partition by session_id
      order by call_seq, tool_call_id
    ) as next_exit_status,
    lead(result_seq) over (
      partition by session_id
      order by call_seq, tool_call_id
    ) as next_result_seq
  from bash_calls
  where command is not null
), failures as (
  select *
  from ordered
  where is_error = 1 or coalesce(exit_status, 0) != 0
)
select
  command_category,
  count(*) as failures,
  sum(case when next_command is null then 1 else 0 end) as no_later_bash,
  sum(case when next_command = command then 1 else 0 end) as immediate_exact_retries,
  sum(
    case
      when next_command = command
       and next_result_seq is not null
       and coalesce(next_is_error, 0) = 0
       and coalesce(next_exit_status, 0) = 0
      then 1 else 0
    end
  ) as exact_retry_successes,
  sum(case when next_category = command_category then 1 else 0 end) as same_category_followups,
  sum(
    case
      when next_command is not null
       and next_result_seq is not null
       and coalesce(next_is_error, 0) = 0
       and coalesce(next_exit_status, 0) = 0
      then 1 else 0
    end
  ) as next_bash_successes
from failures
group by command_category
order by failures desc, command_category;
