-- ============================================================================
-- Q1 — Cohort-wise disbursed loans + ECL, 1 Jul 2026 to 10 Aug 2026
-- ----------------------------------------------------------------------------
-- Answers: how many loans did each cohort (Fresh / Renewal / Dormant) disburse
--          in the window, and what is the ECL on that book?
--
-- ECL SOURCE: analytics.MODEL.LOAN_ECL_METRICS.ECL_PORTFOLIO (NOT M0_ECL, and
-- NOT the old RISK_M0_MODEL_ECL_PREDICTIONS.FINAL_ECL_PRED * 0.88).
--
-- THREE THINGS THAT WILL BITE YOU IF YOU CHANGE THEM:
--  1. BOM must be the LATEST AVAILABLE snapshot, not DATE_TRUNC('MONTH',CURRENT_DATE).
--     Verified 2026-09-11: MAX(BOM) = 2026-09-01.
--  2. The QUALIFY dedup on LOAN_ECL_METRICS is NOT optional. The 2026-09-01
--     snapshot holds 390,223 rows for 320,598 distinct loans — 34,763 loans are
--     exact TRIPLICATES. Drop the QUALIFY and their ECL is counted 3x.
--  3. uw_decision_monitoring must be filtered to the ALLOCATED ARM
--     (model_version = model_version_final). Without it, every BRE run's
--     multiple model-arm rows fan out and inflate the loan counts.
--
-- COHORT DEFINITION (mutually exclusive, evaluated in this order):
--     AA       -> combination_type = 'AA'   (carved out first; per KB rule L14,
--                                            leaving it in double-counts)
--     Dormant  -> is_dormant_flag = 1
--     Renewal  -> is_renewal = 1
--     Fresh    -> everything else
--   'Unmapped' = disbursed loan with no allocated-arm row in uw_decision_monitoring.
--   NOTE is_dormant_flag here is the dashboard definition (BRE input flag with a
--   whitelist fallback), which is NOT the live routing dormancy. See
--   WARN_dormant_flag_definition.
-- ============================================================================

WITH ecl AS (
    SELECT
        a.LOAN_ID,
        a.ECL_PORTFOLIO AS m0_ecl
    FROM analytics.MODEL.LOAN_ECL_METRICS a
    WHERE a.BOM = (SELECT MAX(BOM) FROM analytics.MODEL.LOAN_ECL_METRICS)
    QUALIFY ROW_NUMBER() OVER (PARTITION BY a.LOAN_ID ORDER BY a.BOM DESC) = 1
),

uw AS (   -- allocated arm only, one row per loan (its latest policy run)
    SELECT
        LOAN_ID,
        IS_FRESH,
        IS_RENEWAL,
        IS_DORMANT_FLAG,
        COMBINATION_TYPE
    FROM analytics.model.uw_decision_monitoring
    WHERE MODEL_VERSION = MODEL_VERSION_FINAL
      AND LOAN_ID IS NOT NULL
    QUALIFY ROW_NUMBER() OVER (PARTITION BY LOAN_ID ORDER BY POLICY_RUN_DATE DESC) = 1
),

base AS (
    SELECT
        loc.LOAN_ID,
        loc.LOAN_DISBURSED_DATE,
        loc.LOAN_AMOUNT,
        CASE
            WHEN uw.LOAN_ID IS NULL         THEN 'Unmapped'
            WHEN uw.COMBINATION_TYPE = 'AA' THEN 'AA'
            WHEN uw.IS_DORMANT_FLAG = 1     THEN 'Dormant'
            WHEN uw.IS_RENEWAL = 1          THEN 'Renewal'
            ELSE 'Fresh'
        END AS cohort,
        e.m0_ecl
    FROM analytics.model.loan_origination_characteristics loc
    LEFT JOIN uw  ON loc.LOAN_ID = uw.LOAN_ID
    LEFT JOIN ecl e ON loc.LOAN_ID = e.LOAN_ID
    -- half-open interval: LOAN_DISBURSED_DATE may carry a time component, so
    -- BETWEEN ... AND '2026-08-10' would silently drop most of 10 Aug.
    WHERE loc.LOAN_DISBURSED_DATE >= '2026-07-01'
      AND loc.LOAN_DISBURSED_DATE <  '2026-08-11'
)

SELECT
    cohort,
    COUNT(*)                                                      AS loans,
    ROUND(SUM(LOAN_AMOUNT) / 1e7, 2)                              AS disbursed_cr,
    ROUND(AVG(LOAN_AMOUNT), 0)                                    AS avg_ticket_inr,
    COUNT(m0_ecl)                                                 AS loans_with_ecl,
    ROUND(COUNT(m0_ecl) * 100.0 / COUNT(*), 1)                    AS ecl_coverage_pct,
    ROUND(SUM(m0_ecl) / 1e7, 2)                                   AS ecl_cr,
    -- ECL% on the covered book only, so missing-ECL loans don't dilute the rate
    ROUND(SUM(m0_ecl) * 100.0
          / NULLIF(SUM(CASE WHEN m0_ecl IS NOT NULL THEN LOAN_AMOUNT END), 0), 2) AS ecl_pct
FROM base
GROUP BY ROLLUP(cohort)
ORDER BY (cohort IS NULL), loans DESC
