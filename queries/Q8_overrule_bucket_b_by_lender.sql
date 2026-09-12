-- ============================================================================
-- Q8 — Lender split inside 'POLICY RULES OVERRULE RISK BUCKET B POLICY'
--      Renewal cohort, disbursed 1 Jul 2026 - 10 Aug 2026 (the 500 loans)
-- ----------------------------------------------------------------------------
-- Answers: which lender put the most loans through this experiment, and did
-- their loss rates differ?
--
-- WHY THE CONTROL COLUMNS: a lender showing a high ECL% inside the experiment
-- means nothing on its own — that lender may simply run a riskier book
-- everywhere. The `ctrl_*` columns are the SAME lender's Renewal loans in the
-- SAME window that went through any OTHER experiment. Read across a row:
--   ecl_pct  vs  ctrl_ecl_pct   -> is this experiment worse AT this lender?
-- That separates "bad lender" from "this policy is bad at this lender".
--
-- Baselines for reference: the 500 run at 7.35% ECL; Renewal overall 4.10%;
-- the rest of Renewal (4,810 loans, excluding this experiment) 3.75%.
--
-- LENDER COLUMN: loc.LENDERNAME. LOC also carries VENDOR; they are not always
-- the same string, so do not mix them across queries.
-- ============================================================================

WITH lem AS (
    SELECT a.LOAN_ID, a.ECL_PORTFOLIO, a.MAX_EVER_DPD, a.ACTUAL_DPD_V2
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

-- every non-dormant, non-AA Renewal loan in the window, tagged in/out of the experiment
renewal AS (
    SELECT
        loc.LENDERNAME                      AS lender,
        loc.LOAN_AMOUNT                     AS loan_amount,
        loc.LAST_LOAN_MAX_EVER_DPD          AS prev_dpd,
        lem.ECL_PORTFOLIO                   AS ecl,
        lem.MAX_EVER_DPD                    AS max_ever_dpd,
        IFF(loc.EXPERIMENT_TYPE = 'POLICY RULES OVERRULE RISK BUCKET B POLICY', 1, 0) AS in_exp
    FROM analytics.model.loan_origination_characteristics loc
    JOIN uw  ON loc.LOAN_ID = uw.LOAN_ID
    LEFT JOIN lem ON loc.LOAN_ID = lem.LOAN_ID
    WHERE loc.LOAN_DISBURSED_DATE >= '2026-07-01'
      AND loc.LOAN_DISBURSED_DATE <  '2026-08-11'
      AND uw.COMBINATION_TYPE <> 'AA'
      AND uw.IS_DORMANT_FLAG = 0
      AND uw.IS_RENEWAL = 1
)

SELECT
    lender,

    -- ---- inside the experiment (the 500) ----
    SUM(in_exp)                                                       AS loans,
    ROUND(SUM(in_exp) * 100.0 / SUM(SUM(in_exp)) OVER (), 1)          AS pct_of_500,
    ROUND(SUM(IFF(in_exp = 1, loan_amount, 0)) / 1e7, 2)              AS disbursed_cr,
    ROUND(SUM(IFF(in_exp = 1, ecl, 0)) / 1e7, 3)                      AS ecl_cr,
    ROUND(SUM(IFF(in_exp = 1, ecl, 0)) * 100.0
          / NULLIF(SUM(IFF(in_exp = 1, loan_amount, 0)), 0), 2)       AS ecl_pct,
    -- rupees of loss above what these loans would carry at the bucket's own 7.35%
    ROUND((SUM(IFF(in_exp = 1, ecl, 0))
           - SUM(IFF(in_exp = 1, loan_amount, 0))
             * (SUM(SUM(IFF(in_exp = 1, ecl, 0)))        OVER ()
              / SUM(SUM(IFF(in_exp = 1, loan_amount, 0))) OVER ())) / 1e7, 3) AS excess_vs_bucket_cr,
    ROUND(AVG(IFF(in_exp = 1, IFF(max_ever_dpd >= 4, 1, 0), NULL)) * 100, 1)  AS pct_ever_4dpd,
    ROUND(AVG(IFF(in_exp = 1, prev_dpd, NULL)), 2)                    AS avg_prev_loan_dpd,

    -- ---- same lender, same window, OTHER experiments (control) ----
    SUM(1 - in_exp)                                                   AS ctrl_loans,
    ROUND(SUM(IFF(in_exp = 0, ecl, 0)) * 100.0
          / NULLIF(SUM(IFF(in_exp = 0, loan_amount, 0)), 0), 2)       AS ctrl_ecl_pct,
    ROUND(AVG(IFF(in_exp = 0, IFF(max_ever_dpd >= 4, 1, 0), NULL)) * 100, 1)  AS ctrl_pct_ever_4dpd,

    -- how much worse the experiment is AT THIS LENDER (pp)
    ROUND(SUM(IFF(in_exp = 1, ecl, 0)) * 100.0
            / NULLIF(SUM(IFF(in_exp = 1, loan_amount, 0)), 0)
        - SUM(IFF(in_exp = 0, ecl, 0)) * 100.0
            / NULLIF(SUM(IFF(in_exp = 0, loan_amount, 0)), 0), 2)     AS lift_pp

FROM renewal
GROUP BY lender
HAVING SUM(in_exp) > 0
ORDER BY loans DESC
