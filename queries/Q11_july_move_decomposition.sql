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
-- WHO COUNTS AS "CONTINUING": a lender present in BOTH months with at least 1%
-- of June's Renewal disbursal. The 1% cut is not arbitrary — June's lenders fall
-- either side of it cleanly (LENDBOX 1.67%, then CAPRION 0.57%, then nothing).
-- CAPRION wrote 18 loans / Rs 0.34 Cr in June and 523 in July; calling that a
-- continuing relationship is a technicality, so it is classed as an entrant.
--
-- THE CUT BARELY MOVES THE HEADLINE. Classing CAPRION as continuing instead
-- gives rate +0.5378 vs +0.5365 — the "same lenders got worse" result is robust
-- either way. What it moves is where CAPRION's Rs 9.79 Cr of July volume books:
--   CAPRION as entrant    : rate +0.5365  mix +0.0693  entry/exit +0.5041
--   CAPRION as continuing : rate +0.5378  mix +0.4100  entry/exit +0.1622
-- Same total, same conclusion about the established lenders.
--
-- Verified 2026-09-15 (CAPRION as entrant):
--   rate +0.5365 pp (48.3%)  mix +0.0693 pp (6.2%)  entry/exit +0.5041 pp (45.4%)
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
),

-- materiality rule applied in its own step: Snowflake will not nest window
-- functions, so June's month share has to be materialised before it can be
-- used inside another windowed SUM.
classified AS (
    SELECT
        p.*,
        jun_disb / NULLIF(SUM(jun_disb) OVER (), 0) AS jun_share_of_month,
        IFF(jun_disb / NULLIF(SUM(jun_disb) OVER (), 0) >= 0.01 AND jul_disb > 0,
            'continuing',
            IFF(jul_disb > 0, 'entered', 'exited'))  AS status
    FROM per_lender p
)

SELECT
    lender,
    status,
    jun_loans, jul_loans,
    ROUND(jun_disb / 1e7, 3)                           AS jun_disb_cr,
    ROUND(jul_disb / 1e7, 3)                           AS jul_disb_cr,
    ROUND(jun_ecl * 100.0 / NULLIF(jun_disb, 0), 3)    AS jun_ecl_pct,
    ROUND(jul_ecl * 100.0 / NULLIF(jul_disb, 0), 3)    AS jul_ecl_pct,
    ROUND(jun_share_of_month * 100, 2)                 AS jun_pct_of_month,
    -- weights among CONTINUING lenders only — the shift-share base
    -- NULL for entered/exited: they are not part of the shift-share base
    IFF(status = 'continuing',
        ROUND(jun_disb / NULLIF(SUM(IFF(status = 'continuing', jun_disb, 0)) OVER (), 0), 5), NULL) AS w_jun,
    IFF(status = 'continuing',
        ROUND(jul_disb / NULLIF(SUM(IFF(status = 'continuing', jul_disb, 0)) OVER (), 0), 5), NULL) AS w_jul
FROM classified
ORDER BY jul_disb DESC
