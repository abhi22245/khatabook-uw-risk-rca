-- ============================================================================
-- Q5 — Experiment type x cohort: loan count + ECL, 1 Jul 2026 to 10 Aug 2026
-- ----------------------------------------------------------------------------
-- The four requested columns are: cohort, experiment_type, loans, ecl_cr.
-- disbursed_cr, ecl_pct and excess_ecl_cr are added because absolute ECL only
-- ranks buckets by SIZE — a 1,695-loan experiment will always carry more rupees
-- of loss than a 44-loan one. ecl_pct makes them comparable; excess_ecl_cr is
-- the rupees of loss ABOVE what the bucket would have carried at its own
-- cohort's average rate, which is what actually identifies a problem bucket.
--
-- SOURCE OF experiment_type: loan_origination_characteristics.EXPERIMENT_TYPE.
-- Verified 2026-09-11 over this window: it agrees with
-- LOAN_ECL_METRICS.EXPERIMENT_TYPE on all 17,512 loans, with zero NULLs and
-- 47 distinct values. Do NOT substitute EXPERIMENT_TYPE_FINAL — that is a
-- normalised rollup that differs on 5,123 loans (29%), collapsing
-- 'NORMAL LOAN', '1 BOUNCE POLICY', '2 BOUNCE POLICY' etc. into 'BAU'.
--
-- Cohort / ECL / dedup rules are identical to Q1 — see that file's header for
-- why each QUALIFY is load-bearing.
--
-- NOTE ON excess_ecl_cr: the baseline is PARTITION BY cohort, so each row is
-- measured against its own cohort's rate (Renewal 4.10%, Fresh 4.89%, ...),
-- not against the blended 4.44%. Within one cohort the column sums to ~0.
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
        loc.LOAN_AMOUNT,
        loc.EXPERIMENT_TYPE,
        e.m0_ecl,
        CASE
            WHEN uw.LOAN_ID IS NULL         THEN 'Unmapped'
            WHEN uw.COMBINATION_TYPE = 'AA' THEN 'AA'
            WHEN uw.IS_DORMANT_FLAG = 1     THEN 'Dormant'
            WHEN uw.IS_RENEWAL = 1          THEN 'Renewal'
            ELSE 'Fresh'
        END AS cohort
    FROM analytics.model.loan_origination_characteristics loc
    LEFT JOIN uw  ON loc.LOAN_ID = uw.LOAN_ID
    LEFT JOIN ecl e ON loc.LOAN_ID = e.LOAN_ID
    WHERE loc.LOAN_DISBURSED_DATE >= '2026-07-01'
      AND loc.LOAN_DISBURSED_DATE <  '2026-08-11'
)

SELECT
    cohort,
    EXPERIMENT_TYPE                                   AS experiment_type,
    COUNT(*)                                          AS loans,
    ROUND(SUM(m0_ecl) / 1e7, 3)                       AS ecl_cr,
    ROUND(SUM(LOAN_AMOUNT) / 1e7, 2)                  AS disbursed_cr,
    ROUND(SUM(m0_ecl) * 100.0
          / NULLIF(SUM(LOAN_AMOUNT), 0), 2)           AS ecl_pct,
    ROUND((SUM(m0_ecl) - SUM(LOAN_AMOUNT)
           * (SUM(SUM(m0_ecl))      OVER (PARTITION BY cohort)
            / SUM(SUM(LOAN_AMOUNT)) OVER (PARTITION BY cohort))) / 1e7, 3) AS excess_ecl_cr,
    ROUND(SUM(m0_ecl) * 100.0
          / SUM(SUM(m0_ecl)) OVER (PARTITION BY cohort), 1) AS pct_of_cohort_ecl,
    ROUND(COUNT(*) * 100.0
          / SUM(COUNT(*)) OVER (PARTITION BY cohort), 1)    AS pct_of_cohort_loans
FROM base
GROUP BY cohort, EXPERIMENT_TYPE
ORDER BY cohort, excess_ecl_cr DESC
