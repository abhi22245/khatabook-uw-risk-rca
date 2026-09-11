with d as (
  select loan_id, count(*) as n,
         count(distinct period) as periods, count(distinct mob) as mobs,
         count(distinct ecl_portfolio) as distinct_ecl
  from analytics.MODEL.LOAN_ECL_METRICS
  where bom = '2026-09-01'
  group by 1
)
select n as rows_per_loan, count(*) as loans,
       sum(case when distinct_ecl > 1 then 1 else 0 end) as loans_with_differing_ecl,
       max(periods) as max_distinct_period, max(mobs) as max_distinct_mob
from d group by 1 order by 1
