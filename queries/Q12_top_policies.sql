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
          / NULLIF(SUM(loc.loan_amount), 0), 2)          AS ecl_pct
FROM loc
LEFT JOIN policy p
       ON loc.LOAN_APPLICATION_ID = p.LOAN_APPLICATION_ID
      AND loc.lender_key          = p.lender_key
LEFT JOIN ecl e ON loc.LOAN_ID = e.LOAN_ID
GROUP BY 1, 2, 3
ORDER BY loan_count DESC
LIMIT 10
