-- ============================================================================
-- Q10 — Lender entry / exit inside 'POLICY RULES OVERRULE RISK BUCKET B POLICY'
--       Renewal cohort, monthly, Apr 2025 - 10 Aug 2026
-- ----------------------------------------------------------------------------
-- Why: a lender that only starts appearing in July, or one that was there in
-- June and stopped, would confound any month-over-month read of the bucket.
-- "Bucket got worse" and "bucket changed hands" look identical in an aggregate.
--
-- first_month / last_month are the lender's first and last disbursal month
-- INSIDE this experiment, not their overall relationship with Khatabook — a
-- lender absent here may still be lending heavily on other experiments. The
-- renewal_* columns give that context.
--
-- status classifies each lender by presence in the Jun/Jul/Aug 2026 window:
--   NEW IN JULY      — absent Jun, present Jul
--   EXITED           — present Jun, absent Jul and Aug
--   CONTINUING       — present in Jun and Jul
--   RETURNED         — absent Jun, and last seen before Jun
-- ============================================================================

WITH lem AS (
    SELECT a.LOAN_ID, a.ECL_PORTFOLIO
    FROM analytics.MODEL.LOAN_ECL_METRICS a
    WHERE a.BOM = (SELECT MAX(BOM) FROM analytics.MODEL.LOAN_ECL_METRICS)
    QUALIFY ROW_NUMBER() OVER (PARTITION BY a.LOAN_ID ORDER BY a.BOM DESC) = 1
),

uw AS (
    SELECT LOAN_ID, IS_RENEWAL, IS_DORMANT_FLAG, COMBINATION_TYPE
    FROM analytics.model.uw_decision_monitoring
    WHERE MODEL_VERSION = MODEL_VERSION_FINAL
      AND LOAN_ID IS NOT NULL
    QUALIFY ROW_NUMBER() OVER (PARTITION BY LOAN_ID ORDER BY POLICY_RUN_DATE DESC) = 1
),

renewal AS (
    SELECT
        loc.LENDERNAME                                     AS lender,
        DATE_TRUNC('month', loc.LOAN_DISBURSED_DATE)::DATE AS disb_month,
        loc.LOAN_AMOUNT                                    AS loan_amount,
        lem.ECL_PORTFOLIO                                  AS ecl,
        IFF(loc.EXPERIMENT_TYPE = 'POLICY RULES OVERRULE RISK BUCKET B POLICY', 1, 0) AS in_exp
    FROM analytics.model.loan_origination_characteristics loc
    JOIN uw  ON loc.LOAN_ID = uw.LOAN_ID
    LEFT JOIN lem ON loc.LOAN_ID = lem.LOAN_ID
    WHERE loc.LOAN_DISBURSED_DATE >= '2025-04-01'
      AND loc.LOAN_DISBURSED_DATE <  '2026-08-11'
      AND uw.COMBINATION_TYPE <> 'AA'
      AND uw.IS_DORMANT_FLAG = 0
      AND uw.IS_RENEWAL = 1
)

SELECT
    lender,
    MIN(IFF(in_exp = 1, disb_month, NULL))                       AS first_month_in_exp,
    MAX(IFF(in_exp = 1, disb_month, NULL))                       AS last_month_in_exp,
    COUNT(DISTINCT IFF(in_exp = 1, disb_month, NULL))            AS months_active,
    SUM(in_exp)                                                  AS exp_loans_total,

    SUM(IFF(in_exp = 1 AND disb_month = '2026-06-01', 1, 0))     AS jun26,
    SUM(IFF(in_exp = 1 AND disb_month = '2026-07-01', 1, 0))     AS jul26,
    SUM(IFF(in_exp = 1 AND disb_month = '2026-08-01', 1, 0))     AS aug26,

    CASE
      WHEN SUM(IFF(in_exp = 1 AND disb_month = '2026-06-01', 1, 0)) = 0
       AND SUM(IFF(in_exp = 1 AND disb_month = '2026-07-01', 1, 0)) > 0
       AND MIN(IFF(in_exp = 1, disb_month, NULL)) = '2026-07-01'  THEN 'NEW IN JULY'
      WHEN SUM(IFF(in_exp = 1 AND disb_month = '2026-06-01', 1, 0)) = 0
       AND SUM(IFF(in_exp = 1 AND disb_month = '2026-07-01', 1, 0)) > 0  THEN 'RETURNED IN JULY'
      WHEN SUM(IFF(in_exp = 1 AND disb_month = '2026-06-01', 1, 0)) > 0
       AND SUM(IFF(in_exp = 1 AND disb_month >= '2026-07-01', 1, 0)) = 0 THEN 'EXITED AFTER JUNE'
      WHEN SUM(IFF(in_exp = 1 AND disb_month = '2026-06-01', 1, 0)) > 0  THEN 'CONTINUING'
      ELSE 'not active Jun-Aug'
    END                                                          AS status,

    ROUND(SUM(IFF(in_exp = 1, ecl, 0)) * 100.0
          / NULLIF(SUM(IFF(in_exp = 1, loan_amount, 0)), 0), 2)  AS exp_ecl_pct_alltime,
    -- context: is this lender still lending to Renewal at all outside the experiment?
    SUM(IFF(in_exp = 0 AND disb_month = '2026-06-01', 1, 0))     AS renewal_other_jun26,
    SUM(IFF(in_exp = 0 AND disb_month = '2026-07-01', 1, 0))     AS renewal_other_jul26
FROM renewal
GROUP BY lender
HAVING SUM(in_exp) > 0
ORDER BY jul26 DESC, exp_loans_total DESC
