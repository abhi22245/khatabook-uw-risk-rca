-- ============================================================================
-- Q13 — Lender-wise loans and ECL, 1 Jul 2026 - 20 Aug 2026
-- ----------------------------------------------------------------------------
-- The whole disbursed book by booking lender (LOC.LENDERNAME), not just one
-- cohort or experiment. Cohort split is included because lenders serve very
-- different mixes and a headline ECL% without it is misleading.
--
-- LENDER COLUMN: LOC.LENDERNAME — the lender that actually BOOKED the loan.
-- 11.1% of loans in this window were reassigned, and on every one of them the
-- application's own LENDER already equals LENDERNAME, so this is the final
-- lender, not the originally-assigned one. pct_reassigned shows the share.
--
-- ECL is LOAN_ECL_METRICS.ECL_PORTFOLIO at the latest BOM, deduped per loan
-- (README traps 0-1). Verified 2026-09-21: totals reconcile to Q1 at
-- 22,546 loans / Rs 329.29 Cr / Rs 14.70 Cr ECL / 4.47%.
-- ============================================================================

WITH ecl AS (
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

app AS (
    SELECT DISTINCT id, metadata:lenderReassignmentData AS reassign
    FROM app_backend.loan_service_prod.public_loan_applications_vw
    WHERE DATE(created_at) >= '2026-05-01'
),

base AS (
    SELECT
        loc.LENDERNAME   AS lender,
        loc.LOAN_AMOUNT  AS amt,
        e.ECL_PORTFOLIO  AS ecl,
        ap.reassign,
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
    LEFT JOIN app ap ON loc.LOAN_APPLICATION_ID = ap.id
    WHERE loc.LOAN_DISBURSED_DATE >= '2026-07-01'
      AND loc.LOAN_DISBURSED_DATE <  '2026-08-21'
)

SELECT
    IFF(GROUPING(lender) = 1, 'ALL LENDERS', lender)        AS lender,
    COUNT(*)                                                AS loan_count,
    -- PARTITION BY GROUPING(lender) keeps the ROLLUP row out of the detail
    -- rows' denominator; without it every share is halved.
    ROUND(COUNT(*) * 100.0
          / SUM(COUNT(*)) OVER (PARTITION BY GROUPING(lender)), 1) AS pct_of_loans,
    ROUND(SUM(amt) / 1e7, 2)                                AS disbursed_cr,
    ROUND(SUM(ecl) / 1e7, 3)                                AS ecl_cr,
    ROUND(SUM(ecl) * 100.0 / NULLIF(SUM(amt), 0), 2)        AS ecl_pct,
    ROUND(SUM(ecl) * 100.0
          / SUM(SUM(ecl)) OVER (PARTITION BY GROUPING(lender)), 1) AS pct_of_total_ecl,
    ROUND(AVG(amt), 0)                                      AS avg_ticket_inr,
    ROUND(AVG(IFF(reassign IS NOT NULL, 1, 0)) * 100, 1)    AS pct_reassigned,
    -- cohort mix, so a headline rate is read in context
    ROUND(AVG(IFF(cohort = 'Fresh',   1, 0)) * 100, 1)      AS pct_fresh,
    ROUND(AVG(IFF(cohort = 'Renewal', 1, 0)) * 100, 1)      AS pct_renewal,
    ROUND(AVG(IFF(cohort = 'Dormant', 1, 0)) * 100, 1)      AS pct_dormant
FROM base
GROUP BY ROLLUP(lender)
ORDER BY GROUPING(lender), ecl_cr DESC
