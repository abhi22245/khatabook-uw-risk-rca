-- ============================================================================
-- Q6 — Loan-level detail: Renewal x 'POLICY RULES OVERRULE RISK BUCKET B POLICY'
--      Disbursed 1 Jul 2026 - 10 Aug 2026. Expect exactly 500 rows.
-- ----------------------------------------------------------------------------
-- Purpose: is the bucket's 7.35% ECL driven by a handful of loans, or is it
-- broad-based? Hence the performance columns (MOB, DPD, outstanding) alongside
-- the ECL figures — a loan already deep in DPD explains its own ECL.
--
-- ecl_portfolio is the ECL used everywhere in this analysis.
-- m0_ecl_old is LOAN_ECL_METRICS.M0_ECL, the PREVIOUS ECL definition, carried
-- here only so the two can be compared loan by loan. Do not sum it.
--
-- NOTE: this experiment type has 1,273 loans in the window across ALL cohorts.
-- This query returns only the 500 that are Renewal (non-dormant, non-AA).
-- ============================================================================

WITH lem AS (
    SELECT
        a.LOAN_ID,
        a.ECL_PORTFOLIO,
        a.M0_ECL,
        a.LGD,
        a.MOB,
        a.ACTUAL_DPD_V2,
        a.MAX_EVER_DPD,
        a.PRINCIPAL_OUTSTANDING_V2,
        a.LOAN_STATUS,
        a.EOM_DPD_BAND_V2,
        a.VENDOR
    FROM analytics.MODEL.LOAN_ECL_METRICS a
    WHERE a.BOM = (SELECT MAX(BOM) FROM analytics.MODEL.LOAN_ECL_METRICS)
    QUALIFY ROW_NUMBER() OVER (PARTITION BY a.LOAN_ID ORDER BY a.BOM DESC) = 1
),

uw AS (
    SELECT
        LOAN_ID,
        IS_RENEWAL,
        IS_DORMANT_FLAG,
        COMBINATION_TYPE,
        MODEL_VERSION_FINAL,
        RISK_BUCKET_FINAL,
        MODEL_VERSION_RISK_BAND,
        MODEL_VERSION_CALIB_PD
    FROM analytics.model.uw_decision_monitoring
    WHERE MODEL_VERSION = MODEL_VERSION_FINAL
      AND LOAN_ID IS NOT NULL
    QUALIFY ROW_NUMBER() OVER (PARTITION BY LOAN_ID ORDER BY POLICY_RUN_DATE DESC) = 1
)

SELECT
    loc.LOAN_ID                                   AS loan_id,
    loc.LOAN_DISBURSED_DATE                       AS loan_disbursed_date,
    loc.LOAN_AMOUNT                               AS loan_amount,
    lem.ECL_PORTFOLIO                             AS ecl_portfolio,
    ROUND(lem.ECL_PORTFOLIO * 100.0
          / NULLIF(loc.LOAN_AMOUNT, 0), 2)        AS ecl_pct,
    lem.M0_ECL                                    AS m0_ecl_old,
    lem.LGD                                       AS lgd,
    -- performance as at the ECL snapshot
    lem.MOB                                       AS mob,
    lem.ACTUAL_DPD_V2                             AS actual_dpd_v2,
    lem.MAX_EVER_DPD                              AS max_ever_dpd,
    lem.EOM_DPD_BAND_V2                           AS eom_dpd_band,
    lem.PRINCIPAL_OUTSTANDING_V2                  AS principal_outstanding,
    lem.LOAN_STATUS                               AS loan_status,
    -- decision context
    loc.CREDIT_SCORE                              AS credit_score,
    loc.RISK_BUCKET                               AS risk_bucket_loc,
    uw.RISK_BUCKET_FINAL                          AS risk_bucket_final,
    uw.MODEL_VERSION_FINAL                        AS model_version_final,
    uw.MODEL_VERSION_RISK_BAND                    AS model_risk_band,
    uw.MODEL_VERSION_CALIB_PD                     AS calib_pd,
    loc.LOAN_NUM                                  AS loan_num,
    loc.LAST_LOAN_MAX_EVER_DPD                    AS last_loan_max_ever_dpd,
    loc.TENURE_MONTHS                             AS tenure_months,
    loc.INTEREST_RATE                             AS interest_rate,
    loc.CALCULATED_EDI                            AS calculated_edi,
    loc.ABB90                                     AS abb90,
    loc.LENDERNAME                                AS lender,
    loc.STATE                                     AS state,
    loc.CITY                                      AS city
FROM analytics.model.loan_origination_characteristics loc
JOIN uw  ON loc.LOAN_ID = uw.LOAN_ID
LEFT JOIN lem ON loc.LOAN_ID = lem.LOAN_ID
WHERE loc.LOAN_DISBURSED_DATE >= '2026-07-01'
  AND loc.LOAN_DISBURSED_DATE <  '2026-08-21'
  AND loc.EXPERIMENT_TYPE = 'POLICY RULES OVERRULE RISK BUCKET B POLICY'
  AND uw.COMBINATION_TYPE <> 'AA'
  AND uw.IS_DORMANT_FLAG = 0
  AND uw.IS_RENEWAL = 1
ORDER BY lem.ECL_PORTFOLIO DESC NULLS LAST
