-- ============================================================================
-- Q7 — ECL concentration: the 500 vs healthy control buckets
-- ----------------------------------------------------------------------------
-- Answers: is the overrule bucket's 7.35% a few blow-ups, or broad-based?
--
-- WHY A CONTROL AND NOT THE EVEN-DISTRIBUTION LINE: every credit book is skewed
-- (ECL scales with both loan size and risk), so no real portfolio sits near a
-- perfectly-even distribution. "16% of loans hold half the loss" is meaningless
-- without a benchmark. The benchmark that means something is a HEALTHY bucket
-- from the same cohort and window — here NORMAL LOAN (3.15%) and
-- POLICY RULES OVERRULE POLICY (3.19%).
--
-- Returns one row per loan; compute the concentration curve / Gini downstream.
-- Result (verified 2026-09-12), worst-N share of each bucket's own ECL:
--   NORMAL LOAN      1,695 loans  3.15%  worst 10% -> 48.8%  Gini 0.652
--   OVERRULE POLICY    714 loans  3.19%  worst 10% -> 44.3%  Gini 0.594
--   OVERRULE BUCKET B  500 loans  7.35%  worst 10% -> 37.3%  Gini 0.533
-- Concentration runs OPPOSITE to loss rate: the lossy bucket is the flattest,
-- i.e. worse all the way through rather than carrying a bad tail.
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
    WHERE MODEL_VERSION = MODEL_VERSION_FINAL AND LOAN_ID IS NOT NULL
    QUALIFY ROW_NUMBER() OVER (PARTITION BY LOAN_ID ORDER BY POLICY_RUN_DATE DESC) = 1
)
SELECT
    loc.EXPERIMENT_TYPE        AS bucket,
    loc.LOAN_ID                AS loan_id,
    loc.LOAN_AMOUNT            AS loan_amount,
    COALESCE(lem.ECL_PORTFOLIO, 0) AS ecl
FROM analytics.model.loan_origination_characteristics loc
JOIN uw ON loc.LOAN_ID = uw.LOAN_ID
LEFT JOIN lem ON loc.LOAN_ID = lem.LOAN_ID
WHERE loc.LOAN_DISBURSED_DATE >= '2026-07-01'
  AND loc.LOAN_DISBURSED_DATE <  '2026-08-11'
  AND uw.COMBINATION_TYPE <> 'AA'
  AND uw.IS_DORMANT_FLAG = 0
  AND uw.IS_RENEWAL = 1
  AND loc.EXPERIMENT_TYPE IN ('POLICY RULES OVERRULE RISK BUCKET B POLICY',
                              'NORMAL LOAN',
                              'POLICY RULES OVERRULE POLICY')
