-- ============================================================================
-- Q9 — Did 'POLICY RULES OVERRULE RISK BUCKET B POLICY' grow, or was it always lossy?
--      Renewal cohort, monthly, Apr 2025 - 10 Aug 2026
-- ----------------------------------------------------------------------------
-- This is the question §6.3-6.5 do NOT answer. Those show the bucket is lossy.
-- They do not show it got bigger or worse in July, which is what would make it
-- the CAUSE of Renewal's July deterioration rather than a standing problem.
--
-- Three things to read off this:
--   1. share_of_renewal_pct  — did the bucket GROW as a share of the cohort?
--   2. lift_pp               — bucket ECL% minus rest-of-Renewal ECL% IN THE SAME
--                              MONTH. Seasoning-immune: both sides share a BOM
--                              snapshot and a vintage, so only a real change in
--                              relative quality moves it.
--   3. contribution_pp       — how many pp of Renewal's total ECL% come from
--                              this bucket being worse than the rest:
--                                share_of_disbursal x lift
--                              i.e. remove the bucket's excess and Renewal's ECL%
--                              would fall by roughly this much.
--
-- ecl_pct columns ARE still exposed to seasoning across months (one BOM, older
-- vintages more seasoned) — compare them down a column only loosely. lift_pp is
-- the column to trust for month-over-month change.
--
-- ECL coverage verified 100% for every disbursal month back to Apr 2025, so no
-- survivorship bias from closed loans dropping out of the latest BOM.
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
    disb_month,
    COUNT(*)                                                     AS renewal_loans,
    SUM(in_exp)                                                  AS bucket_loans,
    ROUND(SUM(in_exp) * 100.0 / COUNT(*), 2)                     AS share_of_renewal_pct,
    ROUND(SUM(IFF(in_exp = 1, loan_amount, 0)) * 100.0
          / NULLIF(SUM(loan_amount), 0), 2)                      AS share_of_disbursal_pct,

    ROUND(SUM(IFF(in_exp = 1, ecl, 0)) * 100.0
          / NULLIF(SUM(IFF(in_exp = 1, loan_amount, 0)), 0), 2)  AS bucket_ecl_pct,
    ROUND(SUM(IFF(in_exp = 0, ecl, 0)) * 100.0
          / NULLIF(SUM(IFF(in_exp = 0, loan_amount, 0)), 0), 2)  AS rest_ecl_pct,
    ROUND(SUM(ecl) * 100.0 / NULLIF(SUM(loan_amount), 0), 2)     AS renewal_ecl_pct,

    -- seasoning-immune: same month, same snapshot, both sides
    ROUND(SUM(IFF(in_exp = 1, ecl, 0)) * 100.0
            / NULLIF(SUM(IFF(in_exp = 1, loan_amount, 0)), 0)
        - SUM(IFF(in_exp = 0, ecl, 0)) * 100.0
            / NULLIF(SUM(IFF(in_exp = 0, loan_amount, 0)), 0), 2) AS lift_pp,

    -- pp of Renewal's ECL% attributable to this bucket's excess
    ROUND((SUM(IFF(in_exp = 1, loan_amount, 0)) / NULLIF(SUM(loan_amount), 0))
          * (SUM(IFF(in_exp = 1, ecl, 0)) * 100.0
               / NULLIF(SUM(IFF(in_exp = 1, loan_amount, 0)), 0)
           - SUM(IFF(in_exp = 0, ecl, 0)) * 100.0
               / NULLIF(SUM(IFF(in_exp = 0, loan_amount, 0)), 0)), 3) AS contribution_pp
FROM renewal
GROUP BY disb_month
ORDER BY disb_month
