{{
    config(
        materialized='table',
        schema='model'
    )
}}


with application_level_data as
(
    with
-- okr as (
--  select
--  user_id
--  ,LOAN_APPLICATION_ID
-- ,qd_ts::date as policy_run_date
-- ,case
-- when approval_tag = 'bau' then 'BAU'
-- when approval_tag = 'pre_approved' then 'Pre-Approved' end as Approval_type
-- ,case when loan_type = 'fresh' then 0 else 1 end as is_renewal
-- ,case when loan_type = 'fresh' then 1 else 0 end as is_fresh
-- ,max(case when QD_TYPE = 'fresh_bau' then 'First BRE Run' else 'BRE Rerun' end) as BRE_Run_Flag
-- ,max(case when QD_TYPE = 'fresh_bau' then 1 else 0 end) as is_BRE_first_Run
-- ,min(case when QD_TYPE = 'fresh_bau' then 0 else 1 end) as is_BRE_re_Run
-- ,max(OFFER_FLAG) as OFFER_FLAG
-- from analytics.model.okr_basefact
-- where policy_run_date >= '2025-04-01'
-- group by 1,2,3,4,5,6

-- ),
prr as (
select * from
(
    WITH base_data AS
        (
            select a.*,b.user_id from
                (with
                    offers as
                        (select a.*,b.max_amount_su/100 as offered_amount,1 as OFFER_FLAG, concat(a.loan_application_id,'_',date(a.updated_at)) as join_helper from
                         APP_BACKEND.LOAN_SERVICE_PROD.public_policy_run_results_vw a
                            inner join
                         APP_BACKEND.LOAN_SERVICE_PROD.PUBLIC_LOAN_OFFER_VW b
                         on a.id = b.policy_run_result_id
                         qualify row_number() over(partition by a.loan_application_id,date(a.updated_at) order by success desc,a.updated_at desc) = 1
                        ),
                    all_apps as
                        (select *,0 as offered_amount,0 as OFFER_FLAG, concat(loan_application_id,'_',date(updated_at)) as join_helper
                         from APP_BACKEND.LOAN_SERVICE_PROD.public_policy_run_results_vw
                         qualify row_number() over(partition by loan_application_id,date(updated_at) order by success desc,updated_at desc) = 1
                        )

                    (select * from offers)
                    union
                    (select * from all_apps where join_helper not in (select join_helper from offers))
                ) a
                    left join
                APP_BACKEND.LOAN_SERVICE_PROD.PUBLIC_LOAN_APPLICATIONS_VW b
                on a.loan_application_id = b.id
        ),
    disbursed_loans_data AS
        ( SELECT pl.id AS loan_id,
           pl.user_id,
           pl.disbursed_at AS loan_disbursed_date,
           ROW_NUMBER() OVER (PARTITION BY pl.user_id ORDER BY pl.disbursed_at) AS loan_num
           FROM APP_BACKEND.LOAN_SERVICE_PROD.PUBLIC_LOANS_VW pl
            WHERE pl.status IN ('SETTLED', 'ACTIVE')
        ),
    loan_rank AS
    (SELECT
           *,
           CASE WHEN lap_loan_rank > 1 THEN 'renewal' ELSE 'fresh' END AS loan_type,
               ROW_NUMBER() OVER (PARTITION BY user_id,LAP_LOAN_RANK ORDER BY updated_at) AS BRE_CNT
    FROM
    (
        SELECT
               bd.*,
               CASE WHEN dl.loan_num IS NULL THEN 1 ELSE dl.loan_num + 1 END AS lap_loan_rank
        FROM base_data bd
        LEFT JOIN disbursed_loans_data dl ON bd.user_id = dl.user_id AND DATE(bd.updated_at) > dl.loan_disbursed_date
        QUALIFY ROW_NUMBER() OVER (PARTITION BY bd.user_id, bd.loan_application_id,bd.updated_at ORDER BY dl.loan_disbursed_date DESC) = 1
    )
)
select * from loan_rank
)
where date(updated_at) >= '2025-04-01'
and bre_run_id is not null
),

lor as (
select
distinct
 lor.breRunId
, to_timestamp(to_number(lor.output:timestamp)/1000) + INTERVAL '330 minutes' as bre_run_time
,lor.input:features:activity:IS_DORMANT_FLAG:: int as is_dormant_flag
  ,lor.output:model_config:model_version::string as model_version_final
  ,lor.output:output:Risk_Bucket::string as Risk_Bucket_final
  ,lor.output:output:Sub_Risk_Bucket::string as Sub_Risk_Bucket_final
  ,lor.output:output:COMBINATION_TYPE as COMBINATION_TYPE
  ,lor.output:output:is_swap_in::string as is_swap_in
 ,f.value:version as model_version
 ,f.value:output:Risk_bands as model_version_Risk_band
 ,f.value:output:Sub_Risk_bands as model_version_Sub_Risk_band
 ,f.value:output:is_good_model_override as is_good_model_override
 ,f.value:output:bad_model_scores as bad_model_scores
 ,f.value:output:bad_model_risk_band as bad_model_risk_band
 ,f.value:output:cluster as cluster
 ,f.value:output:good_model_score as good_model_score
 ,f.value:output:Calib_PD as model_version_Calib_PD
from
(select o.user_id,o.loan_application_id,o.created_at,o.updated_at, o.value:breRunId as breRunId,o.value as output, i.value as input
        from
            (select a.*, f.value
                from
                app_backend.loan_service_prod.public_loan_offer_request_vw a,
                lateral flatten (input => a.metadata:scoringServiceOutputHistory) f
                where f.value:breRunId is not null
            ) o
        left join
            (select a.*, f.value
                from
                app_backend.loan_service_prod.public_loan_offer_request_vw a,
                lateral flatten (input => a.metadata:scoringServiceInputHistory) f
                where f.value:breRunId is not null
            ) i
on o.value:breRunId = i.value:breRunId and o.loan_application_id = i.loan_application_id) lor,
lateral flatten(input => lor.output:raw_output:Model_output) f

)
select * exclude(is_dormant_flag),
case when e.kb_id is not null then 1 else 0 end as dormant_flag_final,
coalesce(is_dormant_flag,dormant_flag_final) as is_dormant_flag
from

(select
   user_id
  ,loan_application_id
  ,date(updated_at) as policy_run_date
  ,case when loan_type = 'fresh' then 0 else 1 end as is_renewal
  ,case when loan_type = 'fresh' then 1 else 0 end as is_fresh
  ,case when BRE_CNT = 1 then 'First BRE Run' else 'BRE Rerun' end as BRE_Run_Flag
  ,case when BRE_CNT = 1 then 1 else 0 end as is_BRE_first_Run
  ,case when BRE_CNT = 1 then 0 else 1 end as is_BRE_re_Run
  ,offered_amount
  ,offer_flag
  ,created_at as created_at_prr
  ,updated_at as updated_at_prr
  ,input:KB_INSIGHTS_BANK_BALANCE_90D as KB_INSIGHTS_BANK_BALANCE_90D
  ,input:KB_INSIGHTS_NUM_BANK_CREDIT_30D as KB_INSIGHTS_NUM_BANK_CREDIT_30D
  ,input:KB_INSIGHTS_NUM_BANK_CREDIT_60D as KB_INSIGHTS_NUM_BANK_CREDIT_60D
  ,input:KB_INSIGHTS_NUM_BANK_CREDIT_P30D as KB_INSIGHTS_NUM_BANK_CREDIT_P30D
  ,input:KB_INSIGHTS_SUM_BANK_CREDIT_60D as KB_INSIGHTS_SUM_BANK_CREDIT_60D
  ,success
  ,bre_run_id
  ,id as prr_id
from
prr
) c
left join lor d on c.bre_run_id = d.breRunId
left join (select distinct kb_id from analytics.longterm.lending_dormant_whitelisted_base) e on c.user_id = e.kb_id
),
ewi as (
 with all_apps as(
    with
LOAN_ST_DATE AS (
    SELECT DISTINCT a.LOAN_ID,LOAN_START_DATE, loan_application_id, bre_run_id
    from ANALYTICS.LOG.CREDIT_PERFORMANCE_DAILY a
    inner join
     ( select
 a.*, b.bre_run_id, b.bre_run_time
 from
 analytics.model.loan_origination_characteristics a
 inner join
 (select distinct loan_application_id,bre_run_id, bre_run_time from application_level_data
 where bre_run_id is not null
 ) b
 on a.loan_application_id = b.loan_application_id and a.loan_disbursed_date >= date(b.bre_run_time)
 qualify row_number() over(partition by loan_id order by bre_run_time desc) = 1) b
     on a.loan_id = b.loan_id
),

LOAN_PERF_7D AS (
     SELECT
                    LOAN_ID,
                    STATUS,
                    LOAN_START_DATE,
                    asondate_dpd AS dpd,
                    tilldate_max_dpd AS max_dpd_7D
                FROM (SELECT
                        *, DATEDIFF(DAY, LOAN_START_DATE, FULL_DATE) as DAYS_PAST_LOAN_START
                        FROM ANALYTICS.LOG.CREDIT_PERFORMANCE_DAILY
                        where DAYS_PAST_LOAN_START <= 7
                        QUALIFY row_number()over(partition by LOAN_ID order by DAYS_PAST_LOAN_START desc) =1)
),
LOAN_PERF_10D AS (
     SELECT
                    LOAN_ID,
                    STATUS,
                    LOAN_START_DATE,
                    asondate_dpd AS dpd,
                    tilldate_max_dpd AS max_dpd_10D
                FROM (SELECT
                        *, DATEDIFF(DAY, LOAN_START_DATE, FULL_DATE) as DAYS_PAST_LOAN_START
                        FROM ANALYTICS.LOG.CREDIT_PERFORMANCE_DAILY
                        where DAYS_PAST_LOAN_START <= 10
                        QUALIFY row_number()over(partition by LOAN_ID order by DAYS_PAST_LOAN_START desc) =1)
),
LOAN_PERF_15D AS (
     SELECT
                    LOAN_ID,
                    STATUS,
                    LOAN_START_DATE,
                    asondate_dpd AS dpd,
                    tilldate_max_dpd AS max_dpd_15D
                FROM (SELECT
                        *, DATEDIFF(DAY, LOAN_START_DATE, FULL_DATE) as DAYS_PAST_LOAN_START
                        FROM ANALYTICS.LOG.CREDIT_PERFORMANCE_DAILY
                        where DAYS_PAST_LOAN_START <= 15
                        QUALIFY row_number()over(partition by LOAN_ID order by DAYS_PAST_LOAN_START desc) =1)
),
LOAN_PERF_30D AS (
     SELECT
                    LOAN_ID,
                    STATUS,
                    LOAN_START_DATE,
                    asondate_dpd AS dpd,
                    tilldate_max_dpd AS max_dpd_30D
                FROM (SELECT
                        *, DATEDIFF(DAY, LOAN_START_DATE, FULL_DATE) as DAYS_PAST_LOAN_START
                        FROM ANALYTICS.LOG.CREDIT_PERFORMANCE_DAILY
                        where DAYS_PAST_LOAN_START <= 30
                        QUALIFY row_number()over(partition by LOAN_ID order by DAYS_PAST_LOAN_START desc) =1)
),
LOAN_PERF_45D AS (
     SELECT
                    LOAN_ID,
                    STATUS,
                    LOAN_START_DATE,
                    asondate_dpd AS dpd,
                    tilldate_max_dpd AS max_dpd_45D
                FROM (SELECT
                        *, DATEDIFF(DAY, LOAN_START_DATE, FULL_DATE) as DAYS_PAST_LOAN_START
                        FROM ANALYTICS.LOG.CREDIT_PERFORMANCE_DAILY
                        where DAYS_PAST_LOAN_START <= 45
                        QUALIFY row_number()over(partition by LOAN_ID order by DAYS_PAST_LOAN_START desc) =1)
),
LOAN_PERF_60D AS (
     SELECT
                    LOAN_ID,
                    STATUS,
                    LOAN_START_DATE,
                    asondate_dpd AS dpd,
                    tilldate_max_dpd AS max_dpd_60D
                FROM (SELECT
                        *, DATEDIFF(DAY, LOAN_START_DATE, FULL_DATE) as DAYS_PAST_LOAN_START
                        FROM ANALYTICS.LOG.CREDIT_PERFORMANCE_DAILY
                        where DAYS_PAST_LOAN_START <= 60
                        QUALIFY row_number()over(partition by LOAN_ID order by DAYS_PAST_LOAN_START desc) =1)
),
LOAN_PERF_75D AS (
     SELECT
                    LOAN_ID,
                    STATUS,
                    LOAN_START_DATE,
                    asondate_dpd AS dpd,
                    tilldate_max_dpd AS max_dpd_75D
                FROM (SELECT
                        *, DATEDIFF(DAY, LOAN_START_DATE, FULL_DATE) as DAYS_PAST_LOAN_START
                        FROM ANALYTICS.LOG.CREDIT_PERFORMANCE_DAILY
                        where DAYS_PAST_LOAN_START <= 75
                        QUALIFY row_number()over(partition by LOAN_ID order by DAYS_PAST_LOAN_START desc) =1)
),
LOAN_PERF_90D AS (
     SELECT
                    LOAN_ID,
                    STATUS,
                    LOAN_START_DATE,
                    asondate_dpd AS dpd,
                    tilldate_max_dpd AS max_dpd_90D
                FROM (SELECT
                        *, DATEDIFF(DAY, LOAN_START_DATE, FULL_DATE) as DAYS_PAST_LOAN_START
                        FROM ANALYTICS.LOG.CREDIT_PERFORMANCE_DAILY
                        where DAYS_PAST_LOAN_START <= 90
                        QUALIFY row_number()over(partition by LOAN_ID order by DAYS_PAST_LOAN_START desc) =1)
),
LOAN_PERF_120D AS (
     SELECT
                    LOAN_ID,
                    STATUS,
                    LOAN_START_DATE,
                    asondate_dpd AS dpd,
                    tilldate_max_dpd AS max_dpd_120D
                FROM (SELECT
                        *, DATEDIFF(DAY, LOAN_START_DATE, FULL_DATE) as DAYS_PAST_LOAN_START
                        FROM ANALYTICS.LOG.CREDIT_PERFORMANCE_DAILY
                        where DAYS_PAST_LOAN_START <= 120
                        QUALIFY row_number()over(partition by LOAN_ID order by DAYS_PAST_LOAN_START desc) =1)
)

select a.*, max_dpd_7D,max_dpd_10D,max_dpd_15D,max_dpd_30D,max_dpd_45D,max_dpd_60D,max_dpd_75D,max_dpd_90D,max_dpd_120D
from LOAN_ST_DATE a
left join LOAN_PERF_7D b on a.loan_id = b.loan_id
left join LOAN_PERF_10D c on a.loan_id = c.loan_id
left join LOAN_PERF_15D d on a.loan_id = d.loan_id
left join LOAN_PERF_30D e on a.loan_id = e.loan_id
left join LOAN_PERF_45D f on a.loan_id = f.loan_id
left join LOAN_PERF_60D g on a.loan_id = g.loan_id
left join LOAN_PERF_90D h on a.loan_id = h.loan_id
left join LOAN_PERF_120D i on a.loan_id = i.loan_id
left join LOAN_PERF_75D j on a.loan_id = j.loan_id
where a.loan_start_date >= '2025-04-01')


select LOAN_APPLICATION_ID as LOAN_APPLICATION_ID_LOC,
loan_id,
bre_run_id as bre_run_id_loans,
loan_start_date,max_dpd_7d,max_dpd_10d,max_dpd_15d,
DATEDIFF(DAY, loan_start_date::DATE, CURRENT_DATE) AS loan_age_days,
(case when loan_age_days>=7 then 1 else 0 end ) as num_kb_loans_age_7d,
(case when loan_age_days>=10 then 1 else 0 end ) as num_kb_loans_age_10d,
(case when loan_age_days>=15 then 1 else 0 end ) as num_kb_loans_age_15d,
(case when loan_age_days>=30 then 1 else 0 end ) as num_kb_loans_age_30d,
(case when (max_dpd_7d>=1 and loan_age_days>=7) then 1 else 0 end) as EVER_1DPD_IN_7DAYS,
(case when (max_dpd_7d>=2 and loan_age_days>=7) then 1 else 0 end) as EVER_2DPD_IN_7DAYS,
(case when (max_dpd_7d>=3 and loan_age_days>=7) then 1 else 0 end) as EVER_3DPD_IN_7DAYS,
(case when (max_dpd_7d>=4 and loan_age_days>=7) then 1 else 0 end) as EVER_4DPD_IN_7DAYS,
(case when (max_dpd_7d>=5 and loan_age_days>=7) then 1 else 0 end) as EVER_5DPD_IN_7DAYS,

(case when (max_dpd_10d>=1 and loan_age_days>=10) then 1 else 0 end) as EVER_1DPD_IN_10DAYS,
(case when (max_dpd_10d>=2 and loan_age_days>=10) then 1 else 0 end) as EVER_2DPD_IN_10DAYS,
(case when (max_dpd_10d>=3 and loan_age_days>=10) then 1 else 0 end) as EVER_3DPD_IN_10DAYS,
(case when (max_dpd_10d>=4 and loan_age_days>=10) then 1 else 0 end) as EVER_4DPD_IN_10DAYS,
(case when (max_dpd_10d>=5 and loan_age_days>=10) then 1 else 0 end) as EVER_5DPD_IN_10DAYS,

(case when (max_dpd_15d>=1 and loan_age_days>=15) then 1 else 0 end) as EVER_1DPD_IN_15DAYS,
(case when (max_dpd_15d>=2 and loan_age_days>=15) then 1 else 0 end) as EVER_2DPD_IN_15DAYS,
(case when (max_dpd_15d>=3 and loan_age_days>=15) then 1 else 0 end) as EVER_3DPD_IN_15DAYS,
(case when (max_dpd_15d>=4 and loan_age_days>=15) then 1 else 0 end) as EVER_4DPD_IN_15DAYS,
(case when (max_dpd_15d>=5 and loan_age_days>=15) then 1 else 0 end) as EVER_5DPD_IN_15DAYS,

(case when (max_dpd_30d>=4 and loan_age_days>=30) then 1 else 0 end) as EVER_4DPD_IN_30DAYS,
(case when (max_dpd_30d>=11 and loan_age_days>=30) then 1 else 0 end) as EVER_11DPD_IN_30DAYS,

(case when (max_dpd_60d>=4 and loan_age_days>=60) then 1 else 0 end) as EVER_4DPD_IN_60DAYS,
(case when (max_dpd_60d>=11 and loan_age_days>=60) then 1 else 0 end) as EVER_11DPD_IN_60DAYS,

(case when (max_dpd_75d>=4 and loan_age_days>=75) then 1 else 0 end) as EVER_4DPD_IN_75DAYS,
(case when (max_dpd_75d>=11 and loan_age_days>=75) then 1 else 0 end) as EVER_11DPD_IN_75DAYS,

(case when (max_dpd_90d>=4 and loan_age_days>=90) then 1 else 0 end) as EVER_4DPD_IN_90DAYS,
(case when (max_dpd_90d>=11 and loan_age_days>=90) then 1 else 0 end) as EVER_11DPD_IN_90DAYS
from all_apps
 )

 select *

 from
 application_level_data a
 left join
 ewi e on a.bre_run_id = e.bre_run_id_loans
 qualify row_number() over(partition by loan_application_id, policy_run_date, model_version order by updated_at_prr desc) = 1