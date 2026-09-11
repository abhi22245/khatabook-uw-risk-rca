-- Is the DEPLOYED uw_decision_monitoring.M0_ECL on the new source (ECL_PORTFOLIO)
-- or still the old one (RISK_M0_MODEL_ECL_PREDICTIONS.FINAL_ECL_PRED * 0.88)?
SELECT COUNT(*) AS loans_compared,
       SUM(CASE WHEN ABS(dm.M0_ECL - lem.ECL_PORTFOLIO) < 0.01 THEN 1 ELSE 0 END) AS matches_ecl_portfolio,
       SUM(CASE WHEN ABS(dm.M0_ECL - lem.M0_ECL)        < 0.01 THEN 1 ELSE 0 END) AS matches_lem_m0_ecl,
       ROUND(AVG(dm.M0_ECL),2) AS avg_deployed,
       ROUND(AVG(lem.ECL_PORTFOLIO),2) AS avg_ecl_portfolio,
       ROUND(AVG(lem.M0_ECL),2) AS avg_lem_m0_ecl
FROM analytics.model.uw_decision_monitoring dm
JOIN (
  SELECT LOAN_ID, ECL_PORTFOLIO, M0_ECL
  FROM analytics.MODEL.LOAN_ECL_METRICS
  WHERE BOM = (SELECT MAX(BOM) FROM analytics.MODEL.LOAN_ECL_METRICS)
  QUALIFY ROW_NUMBER() OVER (PARTITION BY LOAN_ID ORDER BY BOM DESC) = 1
) lem ON dm.LOAN_ID = lem.LOAN_ID
WHERE dm.MODEL_VERSION = dm.MODEL_VERSION_FINAL AND dm.M0_ECL IS NOT NULL
