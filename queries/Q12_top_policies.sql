-- ============================================================================
-- Q12 — Top policies by disbursed loans, 1 Jul 2026 - 20 Aug 2026
--       policy_name | lender | experiment_type | loan_count | ecl
-- ----------------------------------------------------------------------------
-- WHERE "POLICY" LIVES. Neither loan_origination_characteristics nor
-- uw_decision_monitoring carries the policy NAME:
--   * LOC.POLICY_TYPE is 'KB' for all 22,546 loans in this window — useless.
--   * LOC has RULE_VERSION / RULE_VERSION_FINAL, which are versions, not names.
--   * uw_decision_monitoring has only POLICY_RUN_DATE.
-- The name (e.g. LENDBOX_ELIGIBILITY_POLICY_VARIANT_2_KB_INSIGHTS) is
-- APP_BACKEND.LOAN_SERVICE_PROD.PUBLIC_POLICY_RUN_RESULTS_VW.POLICY.
--
-- *** THE TRAP THAT MAKES A NAIVE VERSION WRONG ***
-- An application is not run against one policy. Measured over this window:
--     50.3 BRE runs per application
--     45.6 distinct policies per application
--      8.4 distinct LENDERS per application
--   99.8% of applications have runs across MULTIPLE lenders
--   99.1% have MULTIPLE SUCCESSFUL runs
-- So deduping with "QUALIFY ROW_NUMBER() ... ORDER BY SUCCESS DESC, UPDATED_AT
-- DESC" — the dbt model's own preference — picks an essentially ARBITRARY
-- lender's successful policy. It returns a plausible-looking table in which the
-- policy prefix contradicts the booking lender (CASHTREE_... booked by VIVRITI).
--
-- THE FIX: match the run to the lender that actually booked the loan, then
-- prefer a successful run, then the latest. Lender strings differ between the
-- two tables — LOC says 'Western Capital', the BRE says 'WESTERN_CAP' — so they
-- are normalised before joining.
--
-- LENDER REASSIGNMENT. 2,494 of 22,546 loans (11.1%) carry
-- public_loan_applications_vw.metadata:lenderReassignmentData. Verified: on
-- every one of them the application's own LENDER already equals LOC.LENDERNAME,
-- i.e. the record holds the FINAL lender, so the lender-matched join above lands
-- on the right one and reassignment needs no special handling. pct_reassigned is
-- carried per row so a policy serving mostly reassigned loans is visible.
-- Reassigned loans run 4.66% ECL against 4.44% for the rest — slightly worse,
-- not dramatic.
--
-- ORDERING: ecl_pct DESC — riskiest first — with a MINIMUM VOLUME FLOOR of 50
-- loans. The floor is not optional: without it the table is single-loan noise
-- (top row 61.45% on ONE loan, then 44.95% on one, 31.81% on one ...). A rate
-- computed on one loan is not a rate. Change MIN_LOANS below to re-cut it; set
-- it to 0 only if you specifically want the long tail.
--
-- To rank by rupees of loss rather than by rate, order by ecl_cr DESC instead
-- and drop the floor — size already filters out the noise there.
--
-- ECL is LOAN_ECL_METRICS.ECL_PORTFOLIO at the latest BOM, deduped per loan
-- (README traps 0-1). Verified 2026-09-21.
-- ============================================================================

WITH loc AS (
    SELECT
        LOAN_ID,
        LOAN_APPLICATION_ID,
        LENDERNAME       AS lender,
        EXPERIMENT_TYPE  AS experiment_type,
        LOAN_AMOUNT      AS loan_amount,
        -- normalise to the BRE table's spelling
        CASE WHEN UPPER(LENDERNAME) LIKE 'WESTERN%' THEN 'WESTERN_CAP'
             ELSE UPPER(LENDERNAME) END AS lender_key
    FROM analytics.model.loan_origination_characteristics
    WHERE LOAN_DISBURSED_DATE >= '2026-07-01'
      AND LOAN_DISBURSED_DATE <  '2026-08-21'
),

app AS (
    SELECT DISTINCT id, metadata:lenderReassignmentData AS reassign
    FROM app_backend.loan_service_prod.public_loan_applications_vw
    WHERE DATE(created_at) >= '2026-05-01'
),

ecl AS (
    SELECT a.LOAN_ID, a.ECL_PORTFOLIO
    FROM analytics.MODEL.LOAN_ECL_METRICS a
    WHERE a.BOM = (SELECT MAX(BOM) FROM analytics.MODEL.LOAN_ECL_METRICS)
    QUALIFY ROW_NUMBER() OVER (PARTITION BY a.LOAN_ID ORDER BY a.BOM DESC) = 1
),

-- one row per (application, lender): the run that approved it AT THAT LENDER
policy AS (
    SELECT
        a.LOAN_APPLICATION_ID,
        a.LENDER AS lender_key,
        a.POLICY
    FROM APP_BACKEND.LOAN_SERVICE_PROD.PUBLIC_POLICY_RUN_RESULTS_VW a
    WHERE a.UPDATED_AT >= '2026-05-01'
      AND a.LOAN_APPLICATION_ID IN (SELECT LOAN_APPLICATION_ID FROM loc)
    QUALIFY ROW_NUMBER() OVER (PARTITION BY a.LOAN_APPLICATION_ID, a.LENDER
                               ORDER BY a.SUCCESS DESC, a.UPDATED_AT DESC) = 1
)

SELECT
    COALESCE(p.POLICY, '<no BRE run at booking lender>') AS policy_name,
    loc.lender,
    loc.experiment_type,
    COUNT(*)                                             AS loan_count,
    ROUND(SUM(e.ECL_PORTFOLIO) / 1e7, 3)                 AS ecl_cr,
    ROUND(SUM(loc.loan_amount) / 1e7, 2)                 AS disbursed_cr,
    ROUND(SUM(e.ECL_PORTFOLIO) * 100.0
          / NULLIF(SUM(loc.loan_amount), 0), 2)          AS ecl_pct,
    ROUND(AVG(IFF(ap.reassign IS NOT NULL, 1, 0)) * 100, 1) AS pct_reassigned
FROM loc
LEFT JOIN policy p
       ON loc.LOAN_APPLICATION_ID = p.LOAN_APPLICATION_ID
      AND loc.lender_key          = p.lender_key
LEFT JOIN app ap ON loc.LOAN_APPLICATION_ID = ap.id
LEFT JOIN ecl e  ON loc.LOAN_ID = e.LOAN_ID
GROUP BY 1, 2, 3
HAVING COUNT(*) >= 50          -- MIN_LOANS: see ORDERING note in the header
ORDER BY ecl_pct DESC, loan_count DESC
LIMIT 10
