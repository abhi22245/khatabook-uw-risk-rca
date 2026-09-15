-- ============================================================================
-- Q11 — Decomposing Renewal's June -> July 2026 ECL move, by lender
-- ----------------------------------------------------------------------------
-- Supersedes the counterfactual method used in the first pass of §6.6. That one
-- asked "what if the new lenders had performed at the continuing-lender rate",
-- which is an assumption nobody can verify. This is an exact shift-share
-- identity: the three components sum to the total move with no residual and no
-- assumption.
--
--   total move = rate effect + mix effect + entry/exit effect
--
--   rate effect  = SUM over continuing lenders of  w_jun x (r_jul - r_jun)
--                  "the same lenders got worse"
--   mix effect   = SUM over continuing lenders of  (w_jul - w_jun) x r_jul
--                  "volume shifted toward the worse lenders"
--   entry/exit   = total - rate - mix
--                  lenders present in only one of the two months
--
--   w = lender's share of DISBURSED AMOUNT among continuing lenders
--   r = lender's ECL% that month
--   Weight by amount, not loan count — ECL% is an amount-weighted ratio.
--
-- "Continuing" here means literally present in BOTH months, which is the
-- assumption-free cut. Note CAPRION counts as continuing (18 loans in June) even
-- though its July volume is 28x higher; that surge therefore lands in the MIX
-- effect, not entry/exit. That is the correct place for it — the counterparty
-- existed, the allocation to it changed.
--
-- Verified 2026-09-15:
--   rate  +0.5378 pp (48.5%)   mix +0.4100 pp (36.9%)   entry/exit +0.1622 pp (14.6%)
--   total +1.1100 pp, matching 4.1534% - 3.0434% exactly.
--
-- This query returns the per-lender inputs; compute the three effects from them
-- (see README §6.6 for the worked arithmetic).
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

base AS (
    SELECT
        loc.LENDERNAME                                     AS lender,
        DATE_TRUNC('month', loc.LOAN_DISBURSED_DATE)::DATE AS m,
        loc.LOAN_AMOUNT                                    AS amt,
        lem.ECL_PORTFOLIO                                  AS ecl
    FROM analytics.model.loan_origination_characteristics loc
    JOIN uw  ON loc.LOAN_ID = uw.LOAN_ID
    LEFT JOIN lem ON loc.LOAN_ID = lem.LOAN_ID
    WHERE loc.LOAN_DISBURSED_DATE >= '2026-06-01'
      AND loc.LOAN_DISBURSED_DATE <  '2026-08-01'
      AND uw.COMBINATION_TYPE <> 'AA'
      AND uw.IS_DORMANT_FLAG = 0
      AND uw.IS_RENEWAL = 1
),

per_lender AS (
    SELECT
        lender,
        SUM(IFF(m = '2026-06-01', amt, 0)) AS jun_disb,
        SUM(IFF(m = '2026-06-01', ecl, 0)) AS jun_ecl,
        SUM(IFF(m = '2026-07-01', amt, 0)) AS jul_disb,
        SUM(IFF(m = '2026-07-01', ecl, 0)) AS jul_ecl,
        SUM(IFF(m = '2026-06-01', 1, 0))   AS jun_loans,
        SUM(IFF(m = '2026-07-01', 1, 0))   AS jul_loans
    FROM base
    GROUP BY lender
)

SELECT
    lender,
    IFF(jun_disb > 0 AND jul_disb > 0, 'continuing',
        IFF(jul_disb > 0, 'entered', 'exited'))            AS status,
    jun_loans, jul_loans,
    ROUND(jun_disb / 1e7, 3)                               AS jun_disb_cr,
    ROUND(jul_disb / 1e7, 3)                               AS jul_disb_cr,
    ROUND(jun_ecl * 100.0 / NULLIF(jun_disb, 0), 3)        AS jun_ecl_pct,
    ROUND(jul_ecl * 100.0 / NULLIF(jul_disb, 0), 3)        AS jul_ecl_pct,
    -- weights among CONTINUING lenders only (the shift-share base)
    ROUND(jun_disb / NULLIF(SUM(IFF(jun_disb > 0 AND jul_disb > 0, jun_disb, 0)) OVER (), 0), 5) AS w_jun,
    ROUND(jul_disb / NULLIF(SUM(IFF(jun_disb > 0 AND jul_disb > 0, jul_disb, 0)) OVER (), 0), 5) AS w_jul
FROM per_lender
ORDER BY jul_disb DESC
