with
-- Compare failure and cost signals for large inline Bash commands.
-- The 8-line/500-character boundary is an analysis choice, not a causal claim.
shaped as (
  select
    command_category,
    case
      when 1 + length(command) - length(replace(command, char(10), '')) >= 8
        or length(command) >= 500
      then 'large-inline'
      else 'ordinary'
    end as shape,
    duration_ms,
    is_error,
    exit_status,
    output_bytes
  from bash_calls
  where command is not null
)
select
  command_category,
  shape,
  count(*) as calls,
  sum(
    case
      when is_error = 1 or coalesce(exit_status, 0) != 0
      then 1 else 0
    end
  ) as failures,
  round(
    100.0 * sum(
      case
        when is_error = 1 or coalesce(exit_status, 0) != 0
        then 1 else 0
      end
    ) / count(*),
    1
  ) as failure_pct,
  round(avg(duration_ms) / 1000.0, 2) as avg_seconds,
  round(avg(output_bytes), 1) as avg_output_bytes
from shaped
group by command_category, shape
order by command_category, shape;
