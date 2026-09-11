# UW Decision Monitoring — Source Tables Reference

Verified live against Snowflake on 2026-05-28 via
[verify_uw_dcn_tables.py](verify_uw_dcn_tables.py) →
[uw_dcn_table_verification.json](uw_dcn_table_verification.json).

This is the canonical reference for the 8 tables behind
`ANALYTICS.MODEL.UW_DECISION` (the dbt model in [Untitled 3.sql](Untitled%203.sql)).
For each table you get **grain**, **schema**, **what the dbt uses it for**, and
**ready-to-run query patterns** (single-table and joined).

The last section ([Common join recipes](#common-join-recipes)) is a cookbook of
multi-table patterns you'll reach for repeatedly.

---

## Join graph

```
   PUBLIC_LOAN_APPLICATIONS_VW            (loan_application_id, user_id)
                │
                │  loan_application_id
                ▼
   PUBLIC_POLICY_RUN_RESULTS_VW           (one row per BRE run, has bre_run_id, INPUT JSON, OUTPUT JSON)
                │            ▲
   policy_run   │            │ ID = policy_run_result_id
   result_id    │            │
                ▼            │
   PUBLIC_LOAN_OFFER_VW   ────┘            (offered_amount per successful run)


   PUBLIC_LOAN_OFFER_REQUEST_VW            (metadata JSON: scoringServiceOutputHistory[],
                │                                            scoringServiceInputHistory[])
                │  metadata.scoringServiceOutputHistory[].breRunId  ←──  matches
                ▼                                                       PUBLIC_POLICY_RUN_RESULTS_VW.bre_run_id
   <flatten>  →  one row per BRE run per model      (Model_output[].version, Calib_PD, Risk_bands, ...)


   PUBLIC_LOANS_VW                         (one row per disbursed loan, status ACTIVE/SETTLED)
                │  id
                ▼
   ANALYTICS.MODEL.LOAN_ORIGINATION_CHARACTERISTICS   (loan_id, loan_application_id, bureau, KB insights, demographics)
                │  loan_id
                ▼
   ANALYTICS.LOG.CREDIT_PERFORMANCE_DAILY    (one row per loan per day, asondate_dpd, tilldate_max_dpd)


   ANALYTICS.LONGTERM.LENDING_DORMANT_WHITELISTED_BASE   (KB_ID → whitelist membership)
```

**Key bridges** (the high-traffic joins):
| From | To | Join key | What you get |
|---|---|---|---|
| `policy_run_results.ID` | `loan_offer.POLICY_RUN_RESULT_ID` | numeric id | offered amount per run |
| `policy_run_results.LOAN_APPLICATION_ID` | `loan_applications.ID` | numeric id | user_id, lender, mobile |
| `policy_run_results.BRE_RUN_ID` | `loan_offer_request.metadata.scoringServiceOutputHistory[].breRunId` | UUID string (after flatten) | model scores, risk bands, Calib_PD |
| `loans.ID` | `loan_origination_characteristics.LOAN_ID` | numeric id | bureau, KB insights, demographics |
| `loan_origination_characteristics.LOAN_APPLICATION_ID` | `policy_run_results.LOAN_APPLICATION_ID` | numeric id | maps disbursed loans back to the BRE run |
| `credit_performance_daily.LOAN_ID` | `loans.ID` / `loc.LOAN_ID` | numeric id | daily DPD trajectory |
| any `user_id` | `lending_dormant_whitelisted_base.KB_ID` (use `DISTINCT`) | UUID string | dormancy whitelist flag |

---

## 1. `APP_BACKEND.LOAN_SERVICE_PROD.PUBLIC_POLICY_RUN_RESULTS_VW`

| Property | Value |
|---|---|
| Grain | **One row per BRE policy run execution.** |
| Effective PK | `ID` (verified unique: 23,802,888 rows / 23,802,888 distinct IDs in last 30d) |
| Volume | ~23.8 M rows per 30 days — huge, **always filter by date** |
| Columns | 12 |

### Schema
| Column | Type | Purpose |
|---|---|---|
| `ID` | NUMBER(38,0) | PK; matches `PUBLIC_LOAN_OFFER_VW.POLICY_RUN_RESULT_ID` |
| `LOAN_APPLICATION_ID` | NUMBER(38,0) | FK → `PUBLIC_LOAN_APPLICATIONS_VW.ID` |
| `POLICY` | VARCHAR | Policy name (e.g. `GETVANTAGE_ELIGIBILITY_POLICY_VARIANT_2_KB_INSIGHTS`) |
| `SUCCESS` | BOOLEAN | Did the run pass the BRE? |
| `LENDER` | VARCHAR | `GET_VANTAGE`, `LENDBOX`, `JUPITER`, etc. |
| `INPUT` | VARIANT | All features sent to the BRE — 50+ keys incl. the `KB_INSIGHTS_*` family |
| `OUTPUT` | VARIANT | BRE response (eligibility amount, EDI, rejection reasons) — **not the model scoring output** |
| `RULE_ENGINE_RESPONSE` | VARIANT | Raw rule-engine output with policy expression tree |
| `CREATED_AT` | TIMESTAMP_NTZ | |
| `UPDATED_AT` | TIMESTAMP_NTZ | The dbt model uses `date(updated_at)` as `policy_run_date` |
| `BRE_RUN_ID` | VARCHAR | UUID — bridges to `loan_offer_request.metadata.scoringServiceOutputHistory[].breRunId` |
| `RAW_DATA` | VARIANT | Full raw event payload (Kafka source) |

### `INPUT` JSON — verified keys

50 top-level keys per row. The 5 the dbt model extracts:
`KB_INSIGHTS_BANK_BALANCE_90D`, `KB_INSIGHTS_NUM_BANK_CREDIT_30D`, `KB_INSIGHTS_NUM_BANK_CREDIT_60D`,
`KB_INSIGHTS_NUM_BANK_CREDIT_P30D`, `KB_INSIGHTS_SUM_BANK_CREDIT_60D`.

Other useful `KB_INSIGHTS_*` keys also present in `INPUT` (38 more): bounce families
(`NUM_CHEQUE_BOUNCE_*`, `NUM_NACH_BOUNCE_*`, `DEBIT_BOUNCES_*`), overdue families
(`NUM_LOAN_OVERDUE_*`, `NUM_CREDIT_CARD_OVERDUE_*`, `NUM_LOAN_DEFAULT_*`), bank
amounts (`DEBIT_AMOUNT_*`, `SUM_BANK_CREDIT_90D`), `RISK_BUCKET`, `RISK_SUB_BUCKET`,
`PD_RATE_COPY`, `MAX_OVERDUE_AMOUNT_LAST_30D`, `ELIGIBLE_FOR_HIGHER_ATS`.

Plus non-KB core inputs: `AGE`, `CREDIT_SCORE`, `IS_RENEWAL`, `USER_TYPE`, `ABB_EDI_RATIO`,
bureau `ACCOUNT_OPENED_IN_LAST_*` family, etc.

### Standalone query patterns
```sql
-- Daily run volume per policy + success rate
SELECT DATE(updated_at) AS d, POLICY, COUNT(*) AS runs,
       AVG(IFF(SUCCESS, 1, 0))::FLOAT AS success_rate
FROM APP_BACKEND.LOAN_SERVICE_PROD.PUBLIC_POLICY_RUN_RESULTS_VW
WHERE UPDATED_AT >= DATEADD('day', -30, CURRENT_DATE)
GROUP BY 1, 2 ORDER BY 1, 2;

-- Pull KB_INSIGHTS feature distributions from the BRE INPUT
SELECT INPUT:KB_INSIGHTS_BANK_BALANCE_90D::FLOAT AS bb90d,
       INPUT:CREDIT_SCORE::INT                    AS credit_score
FROM APP_BACKEND.LOAN_SERVICE_PROD.PUBLIC_POLICY_RUN_RESULTS_VW
WHERE UPDATED_AT >= DATEADD('day', -7, CURRENT_DATE)
  AND SUCCESS = TRUE;
```

---

## 2. `APP_BACKEND.LOAN_SERVICE_PROD.PUBLIC_LOAN_OFFER_VW`

| Property | Value |
|---|---|
| Grain | **One row per offer generated.** |
| Effective PK | `ID` (verified unique: 1,908,951 rows / 1,908,951 distinct IDs in last 30d) |
| Volume | ~1.9 M rows per 30 days |
| Columns | 22 |

### Schema
| Column | Type | Purpose |
|---|---|---|
| `ID` | NUMBER(38,0) | Offer ID |
| `LOAN_APPLICATION_ID` | NUMBER(38,0) | FK |
| `OFFER_REQUEST_ID` | NUMBER(38,0) | FK → `PUBLIC_LOAN_OFFER_REQUEST_VW.ID` |
| `POLICY_RUN_RESULT_ID` | NUMBER(38,0) | **Main join key** to policy_run_results.ID |
| `MIN_AMOUNT_SU` / `MAX_AMOUNT_SU` | NUMBER | Offer range in paise — divide by 100 for ₹ |
| `MIN_TENURE` / `MAX_TENURE` | NUMBER | Months |
| `ANNUAL_INTEREST_RATE` | FLOAT | Per-period rate the offer carries |
| `ANNUAL_ROI` | FLOAT | Annualized ROI (post all fees) |
| `APR` (see `loans`)…note APR is on `loans`, not here | | |
| `METADATA` | VARIANT | Offer-side JSON (usually small) |
| `LENDER` | VARCHAR | |
| `IS_ACTIVE` | BOOLEAN | Whether offer is still valid |
| `CREATED_AT` / `UPDATED_AT` | TIMESTAMP_NTZ | |
| `UNCAPPED_MAX_AMOUNT_SU` | NUMBER | Pre-cap amount (before any business rule clamp) |
| `MAX_AMOUNT_SU_FROM_ABB_EDI_RATIO` | FLOAT | ABB-EDI ratio cap |
| `PROCESSING_FEE_TYPE` / `PROCESSING_FEE_VALUE` | VARCHAR/FLOAT | |
| `ORIGINAL_PROCESSING_FEE_VALUE` | FLOAT | Pre-override fee |
| `RIGHTSIZED_MAX_AMOUNT_SU` | NUMBER | Final amount after rightsizing logic |
| `RAW_DATA` | VARIANT | |

### How the dbt model uses it
Inside `prr.base_data.offers`:
```sql
inner join PUBLIC_LOAN_OFFER_VW b on a.id = b.policy_run_result_id
```
`max_amount_su / 100` → `offered_amount`. Runs without a matching offer flow through `all_apps` with `offered_amount = 0, OFFER_FLAG = 0`.

### Standalone query patterns
```sql
-- Rightsize / cap impact analysis
SELECT DATE(updated_at), LENDER,
       COUNT(*) AS offers,
       AVG((MAX_AMOUNT_SU - RIGHTSIZED_MAX_AMOUNT_SU) / 100.0)       AS avg_haircut_inr,
       AVG(IFF(UNCAPPED_MAX_AMOUNT_SU > MAX_AMOUNT_SU, 1, 0))         AS pct_capped
FROM APP_BACKEND.LOAN_SERVICE_PROD.PUBLIC_LOAN_OFFER_VW
WHERE UPDATED_AT >= DATEADD('day', -30, CURRENT_DATE) AND IS_ACTIVE
GROUP BY 1, 2;

-- Offer expiry rate per cohort (you'll need IS_ACTIVE = FALSE breakdown joined with applications)
```

---

## 3. `APP_BACKEND.LOAN_SERVICE_PROD.PUBLIC_LOAN_APPLICATIONS_VW`

| Property | Value |
|---|---|
| Grain | **One row per loan application.** |
| Effective PK | `ID` (verified unique: 2,017,038 rows / 2,017,038 distinct IDs in last 30d) |
| Volume | ~2 M rows per 30 days |
| Columns | 15 |

### Schema
| Column | Type | Purpose |
|---|---|---|
| `ID` | NUMBER(38,0) | The `LOAN_APPLICATION_ID` everywhere else |
| `UID` | VARCHAR | Application UUID |
| `USER_ID` | VARCHAR | KB user identifier |
| `LENDER` | VARCHAR | |
| `STATUS` | VARCHAR | `PENDING`, `EXPIRED`, `APPROVED`, `DISBURSED`, … |
| `TYPE` | VARCHAR | E.g. `TERM` |
| `IS_EDITABLE` | BOOLEAN | |
| `CREATED_AT` / `UPDATED_AT` | TIMESTAMP_NTZ | |
| `SESSION_ID` | VARCHAR | |
| `METADATA` | VARIANT | App-creation context, lender assignment, offer-expiry data |
| `EVENT_LOGGABLE` | BOOLEAN | |
| `CREATING_ENTITY` | VARCHAR | What triggered the app |
| `MOBILE_NUMBER` | VARCHAR | |
| `RAW_DATA` | VARIANT | |

### How the dbt model uses it
**Only as a lookup for `USER_ID`** — joined inside `prr.base_data` via `a.loan_application_id = b.id`. `policy_run_results` doesn't carry `user_id` directly.

### Standalone query patterns
```sql
-- Applications by creating entity / status today
SELECT CREATING_ENTITY, STATUS, COUNT(*)
FROM APP_BACKEND.LOAN_SERVICE_PROD.PUBLIC_LOAN_APPLICATIONS_VW
WHERE CREATED_AT >= CURRENT_DATE
GROUP BY 1, 2 ORDER BY 3 DESC;

-- Mobile-number duplicates (multiple user_ids per phone)
SELECT MOBILE_NUMBER, COUNT(DISTINCT USER_ID) AS users
FROM APP_BACKEND.LOAN_SERVICE_PROD.PUBLIC_LOAN_APPLICATIONS_VW
WHERE CREATED_AT >= DATEADD('day', -90, CURRENT_DATE)
GROUP BY 1 HAVING users > 1 ORDER BY 2 DESC;
```

---

## 4. `APP_BACKEND.LOAN_SERVICE_PROD.PUBLIC_LOANS_VW`

| Property | Value |
|---|---|
| Grain | **One row per disbursed loan.** Created at disbursement, updated through lifetime |
| Effective PK | `ID` (verified unique: 8,508 rows / 8,508 distinct IDs in last 30d) |
| Volume | ~8.5 K new disbursements per 30d (cumulative table much larger) |
| Columns | 40 |

### Schema (key columns; full 40 in JSON dump)
| Group | Columns | Notes |
|---|---|---|
| **IDs** | `ID`, `USER_ID`, `UID`, `VENDOR_LOAN_ID`, `LOAN_APPLICATION_NUM`, `SHORT_ID` | `ID` = the canonical `LOAN_ID` everywhere else |
| **Loan terms** | `PRINCIPAL_AMOUNT_SU`, `DISBURSAL_AMOUNT_SU`, `EXPECTED_AMOUNT_SU`, `TENURE_MONTHS`, `INTEREST_RATE`, `IRR`, `IRR_V2`, `APR`, `ADVANCE_EMI_AMOUNT_SU` | All `*_SU` are in paise — divide by 100 for ₹ |
| **Status** | `STATUS` (`ACTIVE`/`SETTLED`), `SUB_STATUS` | dbt filters to `STATUS IN ('SETTLED', 'ACTIVE')` |
| **Outstanding** | `OUTSTANDING_LOAN_AMOUNT_SU`, `OVERDUE_AMOUNT_SU_TILL_DATE`, `TOTAL_AMOUNT_PAID_SU`, `LATE_FEE_AMOUNT_PAID_SU`, `CURRENT_LATE_FEE_AMOUNT_SU` | Live balance — use this for portfolio snapshots |
| **DPD (live)** | `CURRENT_DPD`, `CURRENT_DPD_V2`, `MAX_DPD`, `MAX_DPD_V2`, `ADJUSTED_RPS_CURRENT_DPD_V2`, `ADJUSTED_RPS_MAX_DPD_V2`, `ADJUSTED_RPS_OVERDUE_AMOUNT_SU_TILL_DATE` | `_V2` is the current standard. `ADJUSTED_RPS_*` corrects for repayment-schedule resets |
| **Dates** | `CREATED_AT`, `UPDATED_AT`, `DISBURSED_AT`, `CLOSED_AT`, `SYNCED_AT`, `LOAN_STATE_UPDATED_AT` | `DISBURSED_AT` drives loan-sequencing logic |
| **Flags** | `IS_NACH_AUTOMATION_ENABLED`, `IS_LENDER_PAYMENT_SPLIT_ENABLED` | |
| **Vendor** | `VENDOR`, `VENDOR_LOAN_ID` | Lender + their internal loan ID |
| **Misc** | `METADATA`, `RAW_DATA` | Variant payloads |

### How the dbt model uses it
Only for **loan sequencing** to derive fresh vs renewal:
```sql
SELECT id, user_id, disbursed_at,
       ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY disbursed_at) AS loan_num
FROM PUBLIC_LOANS_VW WHERE STATUS IN ('SETTLED', 'ACTIVE')
```

### Standalone query patterns
```sql
-- Live portfolio snapshot (no credit_performance_daily needed)
SELECT STATUS, COUNT(*) AS loans,
       SUM(OUTSTANDING_LOAN_AMOUNT_SU) / 100.0 / 1e7 AS outstanding_cr,
       AVG(CURRENT_DPD_V2)                          AS avg_current_dpd,
       SUM(IFF(CURRENT_DPD_V2 >= 30, 1, 0))         AS loans_30dpd,
       SUM(IFF(CURRENT_DPD_V2 >= 90, 1, 0))         AS loans_90dpd
FROM APP_BACKEND.LOAN_SERVICE_PROD.PUBLIC_LOANS_VW
WHERE STATUS IN ('ACTIVE', 'SETTLED')
GROUP BY 1;

-- Disbursal trend by lender
SELECT DATE_TRUNC('month', DISBURSED_AT) AS mth, VENDOR,
       COUNT(*) AS disbursed,
       SUM(DISBURSAL_AMOUNT_SU) / 100.0 / 1e7 AS disb_cr
FROM APP_BACKEND.LOAN_SERVICE_PROD.PUBLIC_LOANS_VW
WHERE DISBURSED_AT >= DATEADD('month', -6, CURRENT_DATE)
GROUP BY 1, 2 ORDER BY 1, 2;
```

> **Note on joining to loan_application_id:** `PUBLIC_LOANS_VW` does NOT carry `loan_application_id` directly. To get from a loan back to its application, hop through `LOAN_ORIGINATION_CHARACTERISTICS` (which has both).

---

## 5. `APP_BACKEND.LOAN_SERVICE_PROD.PUBLIC_LOAN_OFFER_REQUEST_VW`

| Property | Value |
|---|---|
| Grain | **One row per loan offer request.** Each application may have ≥1. |
| Effective PK | `ID` (verified unique: 1,125,093 rows / 1,125,093 distinct IDs in last 30d) |
| Volume | ~1.1 M rows per 30d |
| Columns | 18 |

### Schema
| Column | Type | Purpose |
|---|---|---|
| `ID` | NUMBER(38,0) | Request ID |
| `UID` | VARCHAR | UUID |
| `USER_ID` | VARCHAR | |
| `TYPE` | VARCHAR | `DEFAULT`, etc. |
| `STATUS` | VARCHAR | `OFFER_READY`, etc. |
| `LOAN_TYPE` | VARCHAR | `TERM`, etc. |
| `LOAN_APPLICATION_ID` | NUMBER(38,0) | |
| `LENDER` | VARCHAR | |
| `METADATA` | VARIANT | **The critical column** — see JSON section below |
| `INSIGHTS_DATA` | VARIANT | Often NULL |
| `INSIGHTS_DATA_KB` | VARIANT | KB-side insights JSON (250+ feature keys) |
| `POLICY_RESULT` | VARIANT | Usually `{}` |
| `EXPIRE_AT` / `CREATED_AT` / `UPDATED_AT` / `SMS_DISQUAL_BRE_LAST_RUN_AT` | TIMESTAMP_NTZ | |
| `BRE_RUN_ID` | VARCHAR | **Frequently NULL on the row itself.** Real per-BRE-run IDs live inside `metadata.scoringServiceOutputHistory[].breRunId` |
| `RAW_DATA` | VARIANT | |

### `METADATA` JSON — top-level keys (verified, 30 total)
```
scoringServiceInput, scoringServiceInputHistory,
scoringServiceOutput, scoringServiceOutputHistory,
foir, generateOfferExperimentData,
KbLlmVendorInsightId, KbVendorInsightId,
internallyGeneratedAAInsights,
isBizAnalystCounterPartyUser, isDBRExperimentUser, isDeviceConnectSkipped,
isDewhitelistingUser, isDormantUser, isHighRiskPincodeApplication,
isIosUser, isKbPolicyRunSuccessful, isNonPhysicallyServiceable,
isPreM6VintageExperimentApplication,
latestInsightsPullTimestamp, offerDelayedNotificationSentAt, pincode,
reCreditReportData, reLedgerData, reRenewalData, reUserData, reVendorInsightsDataKb,
useKbInsightsForDecisioning, userTagData, waitTimeTracking
```

### `scoringServiceOutputHistory[i]` element shape
```
{
  breRunId,                  // matches PUBLIC_POLICY_RUN_RESULTS_VW.BRE_RUN_ID
  isFresh,
  model_assignment,
  model_config: { model_version, ... },
  output: {
    Risk_Bucket, Sub_Risk_Bucket, COMBINATION_TYPE, is_swap_in, ...
  },
  raw_output: {
    // 400+ feature key/values used at decision time, plus:
    Model_output: [ {version, output}, ... ]      // one entry per model that ran
  },
  timestamp                  // epoch micros
}
```

### `raw_output.Model_output[i]` inner `output` keys (v4 family)
```
Calib_PD, Risk_bands, Sub_Risk_bands,
Br_PD, SMS_PD, Trx_PD, Combined_PD, Combined_logodds,
Calib_SMS_BR, Calib_SMS_TX, Calib_SMS_BR_TX,
logodds_br, logodds_sms, logodds_trx,
pred_br, pred_sms, pred_trx
```
A real row had **6 model entries** under one BRE run (multiple model versions scored side-by-side).

> **v5-imputed family** also emits `good_model_score`, `bad_model_scores`, `bad_model_risk_band`, `is_good_model_override`, `cluster`. v4 rows do not — those keys come back as NULL. See [DORMANT_MODEL_INVESTIGATION.md](DORMANT_MODEL_INVESTIGATION.md) for v5 architecture context.

### `scoringServiceInputHistory[i].features` structure
```
features: {
  activity:    { IS_DORMANT_FLAG, NUM_CLICKED_BUTTON_*, KB_ID, ... },
  bureau:      { ... },
  ledger:      { ... },
  location:    { ... },
  performance: { ... },
  sms:         { ... }
}
```
The dbt reads `input:features:activity:IS_DORMANT_FLAG` from here.

### Standalone query patterns
```sql
-- Calib_PD for a specific model version across recent BRE runs
SELECT lor.LOAN_APPLICATION_ID,
       o.value:breRunId::STRING                 AS bre_run_id,
       o.value:timestamp::NUMBER                AS ts_epoch_micros,
       m.value:version::STRING                  AS model_version,
       m.value:output:Calib_PD::FLOAT           AS calib_pd,
       m.value:output:Risk_bands::STRING        AS risk_band
FROM APP_BACKEND.LOAN_SERVICE_PROD.PUBLIC_LOAN_OFFER_REQUEST_VW lor,
LATERAL FLATTEN (input => lor.metadata:scoringServiceOutputHistory) o,
LATERAL FLATTEN (input => o.value:raw_output:Model_output)          m
WHERE lor.UPDATED_AT >= DATEADD('day', -1, CURRENT_DATE)
  AND m.value:version::STRING IN ('v5.0.0_imputed', 'v5.0.1_imputed');

-- Pull one raw feature from the BRE input
SELECT lor.LOAN_APPLICATION_ID,
       i.value:breRunId::STRING                                   AS bre_run_id,
       i.value:features:bureau:CREDIT_SCORE::INT                  AS credit_score,
       i.value:features:activity:IS_DORMANT_FLAG::INT             AS is_dormant,
       i.value:features:sms:NUM_CHEQUE_BOUNCES_120D::FLOAT        AS cheque_bounces_120d
FROM APP_BACKEND.LOAN_SERVICE_PROD.PUBLIC_LOAN_OFFER_REQUEST_VW lor,
LATERAL FLATTEN (input => lor.metadata:scoringServiceInputHistory) i
WHERE lor.UPDATED_AT >= DATEADD('day', -1, CURRENT_DATE);
```

---

## 6. `ANALYTICS.MODEL.LOAN_ORIGINATION_CHARACTERISTICS`

| Property | Value |
|---|---|
| Grain | **One row per disbursed loan**, enriched with ~120 origination-time features |
| Effective PK | `LOAN_ID` (verified unique: 8,328 rows / 8,328 distinct LOAN_IDs in last 30d) |
| Volume | Tracks `PUBLIC_LOANS_VW` (~8.3 K new per 30d) with slight ETL lag |
| Columns | 123 |

### Schema groupings (123 cols — only the actionable slice)
| Group | Columns | Notes |
|---|---|---|
| **IDs** | `LOAN_ID`, `CUSTOMER_ID`, `LOAN_APPLICATION_ID`, `LAST_LOAN_ID`, `LAN_NUMBER`, `VENDOR_LOAN_ID` | `CUSTOMER_ID` here ≡ `USER_ID` elsewhere. `LOAN_APPLICATION_ID` is the bridge back to BRE land |
| **Dates** | `LOAN_DISBURSED_DATE`, `POLICY_RUN_DATE`, `FIRST_EDI_DATE`, `LAST_REPAYMENT_DATE`, `ACTUAL_LOAN_END_DATE`, `SCHEDULED_LOAN_END_DATE`, `KB_USER_CREATION_DATE` | |
| **Loan terms** | `LOAN_AMOUNT`, `DISBURSED_AMOUNT`, `INTEREST_RATE`, `TENURE_MONTHS`, `CALCULATED_EDI`, `REPAYMENT_AMOUNT`, `OFFERED_AMOUNT`, `OFFERED_TENURE`, `ACTUAL_IDEAL_EDI` | Already in ₹ here (not paise) |
| **Sequencing** | `LOAN_NUM`, `LOAN_TYPE` (`fresh`/`renewal`), `APP_VINTAGE_IN_DAYS_AT_DISBURSAL` | Useful for renewal cohorts without recomputing |
| **Decision context** | `RULE_VERSION_FINAL`, `RULE_VERSION`, `CREDIT_SCORE`, `RISK_BUCKET` | Snapshot of what the BRE decided |
| **KB-insight numerics** | `ABB90`, `CREDIT_AMT_60DAYS`, `CREDITS_CNT_C30`, `CREDITS_CNT_P30`, … (~30 KB cols) | |
| **Bureau** | `CREDIT_REPORT_*` family | External credit history at origination |
| **DPD lifetime** | `MAX_EVER_DPD`, `LAST_LOAN_MAX_EVER_DPD` | Convenience aggregates over the user's history |
| **Misc** | `LENDERNAME`, `VENDOR`, `PHONE`, `UPI_FLAG`, `LOAN_STATUS` | |

### How the dbt model uses it
Only as a bridge in `LOAN_ST_DATE` to map `loan_application_id` ↔ `loan_id` (so that `credit_performance_daily.loan_id` can be looked up).

### Standalone query patterns
```sql
-- Bureau credit score distribution by month for disbursed loans
SELECT DATE_TRUNC('month', LOAN_DISBURSED_DATE) AS mth,
       PERCENTILE_CONT(0.5)  WITHIN GROUP (ORDER BY CREDIT_SCORE) AS p50,
       PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY CREDIT_SCORE) AS p95,
       COUNT(*) AS loans
FROM ANALYTICS.MODEL.LOAN_ORIGINATION_CHARACTERISTICS
WHERE LOAN_DISBURSED_DATE >= '2025-04-01'
GROUP BY 1 ORDER BY 1;

-- Renewal share over time
SELECT DATE_TRUNC('month', LOAN_DISBURSED_DATE) AS mth,
       AVG(IFF(LOAN_TYPE = 'renewal', 1, 0)) AS renewal_share
FROM ANALYTICS.MODEL.LOAN_ORIGINATION_CHARACTERISTICS
WHERE LOAN_DISBURSED_DATE >= '2025-04-01'
GROUP BY 1 ORDER BY 1;
```

---

## 7. `ANALYTICS.LOG.CREDIT_PERFORMANCE_DAILY`

| Property | Value |
|---|---|
| Grain | **One row per loan per day.** |
| Effective PK | `(LOAN_ID, FULL_DATE)` (verified unique: 2,924,249 rows / 2,924,249 distinct in last 30d) |
| Volume | ~2.9 M rows in last 30 days alone. Billion-row table overall — **always filter** |
| Columns | 10 |

### Schema (all 10 columns)
| Column | Type | Meaning |
|---|---|---|
| `LOAN_ID` | NUMBER(38,0) | FK to loans |
| `STATUS` | VARCHAR | Loan status on that day |
| `FULL_DATE` | DATE | Observation date |
| `LOAN_START_DATE` | DATE | Disbursement date (denormalized) |
| `ACTUAL_LOAN_END_DATE` | DATE | When the loan closed (NULL if still open) |
| `BOD_DPD` | NUMBER(38,0) | DPD at beginning of day |
| `ACTUAL_DPD` | NUMBER(38,0) | True DPD calculated |
| `EOD_DPD` | NUMBER(38,0) | DPD at end of day |
| `ASONDATE_DPD` | NUMBER(38,0) | DPD **as of FULL_DATE** (point-in-time) |
| `TILLDATE_MAX_DPD` | NUMBER(38,0) | **Max DPD ever from LOAN_START_DATE to FULL_DATE.** This is the column EVER-*DPD flags are derived from |

### How the dbt model uses it
- `LOAN_ST_DATE` — grabs `LOAN_START_DATE` per loan.
- `LOAN_PERF_XD` (9 CTEs at 7/10/15/30/45/60/75/90/120D) — for each loan, takes the latest `FULL_DATE` with `DAYS_PAST_LOAN_START <= X`, then reads `TILLDATE_MAX_DPD` as `max_dpd_XD`.

This is the **outcome table** — everything downstream (EVER_XDPD_IN_YDAYS flags, Gini, vintage curves) is derived from it.

### Standalone query patterns
```sql
-- DPD trajectory of one loan
SELECT FULL_DATE, ASONDATE_DPD, TILLDATE_MAX_DPD, STATUS
FROM ANALYTICS.LOG.CREDIT_PERFORMANCE_DAILY
WHERE LOAN_ID = <loan_id>
ORDER BY FULL_DATE;

-- 30/60/90 DPD curve at day-X across a disbursal cohort
WITH cohort AS (
  SELECT DISTINCT LOAN_ID, LOAN_START_DATE
  FROM ANALYTICS.LOG.CREDIT_PERFORMANCE_DAILY
  WHERE LOAN_START_DATE >= '2025-04-01' AND LOAN_START_DATE < '2025-05-01'
), dpd AS (
  SELECT c.LOAN_ID,
         MAX(IFF(DATEDIFF(DAY, c.LOAN_START_DATE, d.FULL_DATE) <= 30,  d.TILLDATE_MAX_DPD, 0)) AS dpd_30,
         MAX(IFF(DATEDIFF(DAY, c.LOAN_START_DATE, d.FULL_DATE) <= 60,  d.TILLDATE_MAX_DPD, 0)) AS dpd_60,
         MAX(IFF(DATEDIFF(DAY, c.LOAN_START_DATE, d.FULL_DATE) <= 90,  d.TILLDATE_MAX_DPD, 0)) AS dpd_90,
         MAX(IFF(DATEDIFF(DAY, c.LOAN_START_DATE, d.FULL_DATE) <= 120, d.TILLDATE_MAX_DPD, 0)) AS dpd_120
  FROM cohort c
  JOIN ANALYTICS.LOG.CREDIT_PERFORMANCE_DAILY d USING (LOAN_ID)
  GROUP BY 1
)
SELECT COUNT(*) AS loans,
       AVG(IFF(dpd_30  >= 1, 1, 0)) AS ever1dpd_30d,
       AVG(IFF(dpd_60  >= 4, 1, 0)) AS ever4dpd_60d,
       AVG(IFF(dpd_90  >= 4, 1, 0)) AS ever4dpd_90d,
       AVG(IFF(dpd_120 >= 4, 1, 0)) AS ever4dpd_120d
FROM dpd;
```

---

## 8. `ANALYTICS.LONGTERM.LENDING_DORMANT_WHITELISTED_BASE`

| Property | Value |
|---|---|
| Grain | Roughly one row per whitelisted user — **5,240 duplicate KB_IDs** exist (50,882,020 rows / 50,876,780 distinct). Always `SELECT DISTINCT` when joining |
| Effective PK | `KB_ID` (after dedup) |
| Volume | ~50.9 M total rows |
| Columns | 4 |

### Schema
| Column | Type | Note |
|---|---|---|
| `KB_ID` | VARCHAR | = `user_id` elsewhere |
| `WHITELISTED_DATE` | DATE | When whitelisted |
| `WHITELISTED_COHORT` | VARCHAR(32) | E.g. `"a. June Whitelisted - 5M Base"` |
| `WHITELIST_TYPE` | VARCHAR | E.g. `"Dormant"` |

### How the dbt model uses it
```sql
left join (select distinct kb_id from analytics.longterm.lending_dormant_whitelisted_base) e
  on c.user_id = e.kb_id
```
Then:
```sql
case when e.kb_id is not null then 1 else 0 end as dormant_flag_final,
coalesce(is_dormant_flag, dormant_flag_final) as is_dormant_flag
```
Prefers the real-time BRE input `IS_DORMANT_FLAG`; falls back to whitelist membership if NULL.

### Standalone query patterns
```sql
-- Whitelist cohort composition
SELECT WHITELISTED_COHORT, WHITELIST_TYPE,
       COUNT(*) AS rows_, COUNT(DISTINCT KB_ID) AS users,
       MIN(WHITELISTED_DATE), MAX(WHITELISTED_DATE)
FROM ANALYTICS.LONGTERM.LENDING_DORMANT_WHITELISTED_BASE
GROUP BY 1, 2 ORDER BY 3 DESC;
```

---

## Common join recipes

Recipes you'll reach for again and again. Each one is copy-paste runnable.

### R1. BRE run + offer outcome + user_id (the dbt's `prr` slice)
> For a date range, get every BRE policy run with whether it produced an offer, the offered amount, and the user_id.

```sql
WITH offers AS (
  SELECT a.id AS prr_id, a.loan_application_id, a.bre_run_id, a.policy, a.success,
         a.lender, a.updated_at,
         b.max_amount_su / 100 AS offered_amount, 1 AS offer_flag
  FROM APP_BACKEND.LOAN_SERVICE_PROD.PUBLIC_POLICY_RUN_RESULTS_VW a
  INNER JOIN APP_BACKEND.LOAN_SERVICE_PROD.PUBLIC_LOAN_OFFER_VW b
    ON a.id = b.policy_run_result_id
  WHERE a.updated_at >= '2025-04-01' AND a.bre_run_id IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (PARTITION BY a.loan_application_id, DATE(a.updated_at)
                             ORDER BY a.success DESC, a.updated_at DESC) = 1
),
all_runs AS (
  SELECT a.id AS prr_id, a.loan_application_id, a.bre_run_id, a.policy, a.success,
         a.lender, a.updated_at,
         0 AS offered_amount, 0 AS offer_flag
  FROM APP_BACKEND.LOAN_SERVICE_PROD.PUBLIC_POLICY_RUN_RESULTS_VW a
  WHERE a.updated_at >= '2025-04-01' AND a.bre_run_id IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (PARTITION BY a.loan_application_id, DATE(a.updated_at)
                             ORDER BY a.success DESC, a.updated_at DESC) = 1
),
combined AS (
  SELECT * FROM offers
  UNION ALL
  SELECT * FROM all_runs r
  WHERE NOT EXISTS (SELECT 1 FROM offers o
                    WHERE o.loan_application_id = r.loan_application_id
                      AND DATE(o.updated_at) = DATE(r.updated_at))
)
SELECT c.*, la.user_id, la.mobile_number, la.status AS app_status
FROM combined c
LEFT JOIN APP_BACKEND.LOAN_SERVICE_PROD.PUBLIC_LOAN_APPLICATIONS_VW la
  ON c.loan_application_id = la.id;
```

### R2. BRE run + model scores per model version (the dbt's `lor` slice)
> One row per (BRE run, model_version) with Calib_PD, Risk_bands.

```sql
SELECT lor.LOAN_APPLICATION_ID,
       o.value:breRunId::STRING                                    AS bre_run_id,
       TO_TIMESTAMP(o.value:timestamp::NUMBER / 1000)
         + INTERVAL '330 minutes'                                  AS bre_run_time_ist,
       o.value:model_config:model_version::STRING                  AS model_version_final,
       o.value:output:Risk_Bucket::STRING                          AS risk_bucket_final,
       o.value:output:COMBINATION_TYPE::STRING                     AS combination_type,
       m.value:version::STRING                                     AS model_version,
       m.value:output:Calib_PD::FLOAT                              AS calib_pd,
       m.value:output:Risk_bands::STRING                           AS risk_band,
       m.value:output:Sub_Risk_bands::STRING                       AS sub_risk_band
FROM APP_BACKEND.LOAN_SERVICE_PROD.PUBLIC_LOAN_OFFER_REQUEST_VW lor,
LATERAL FLATTEN (input => lor.metadata:scoringServiceOutputHistory) o,
LATERAL FLATTEN (input => o.value:raw_output:Model_output)           m
WHERE lor.UPDATED_AT >= DATEADD('day', -30, CURRENT_DATE)
  AND o.value:breRunId IS NOT NULL;
```

### R3. BRE decision joined to model scores (R1 ⨝ R2 on bre_run_id)
> For each BRE run: app context + model version outputs. This is essentially what the dbt's `application_level_data` produces.

```sql
WITH prr AS ( /* R1 above */ ),
     lor AS ( /* R2 above */ )
SELECT prr.loan_application_id, prr.user_id, DATE(prr.updated_at) AS policy_run_date,
       prr.policy, prr.success, prr.lender, prr.offered_amount, prr.offer_flag,
       lor.model_version, lor.calib_pd, lor.risk_band,
       lor.model_version_final, lor.risk_bucket_final
FROM prr
LEFT JOIN lor ON prr.bre_run_id = lor.bre_run_id;
```

### R4. Disbursed loan + decision-time features + early DPD
> The full origination-to-outcome chain for one cohort.

```sql
WITH loans AS (
  SELECT id AS loan_id, user_id, disbursed_at, principal_amount_su, status, vendor
  FROM APP_BACKEND.LOAN_SERVICE_PROD.PUBLIC_LOANS_VW
  WHERE DISBURSED_AT >= '2025-04-01' AND status IN ('ACTIVE', 'SETTLED')
),
loc AS (
  SELECT loan_id, loan_application_id, credit_score, risk_bucket,
         loan_type, loan_num, app_vintage_in_days_at_disbursal,
         abb90, last_loan_max_ever_dpd
  FROM ANALYTICS.MODEL.LOAN_ORIGINATION_CHARACTERISTICS
),
dpd_30 AS (
  SELECT loan_id, tilldate_max_dpd AS max_dpd_30d
  FROM (
    SELECT *, DATEDIFF(DAY, loan_start_date, full_date) AS days_past_start
    FROM ANALYTICS.LOG.CREDIT_PERFORMANCE_DAILY
    WHERE days_past_start <= 30
    QUALIFY ROW_NUMBER() OVER (PARTITION BY loan_id ORDER BY days_past_start DESC) = 1
  )
),
dpd_90 AS (
  SELECT loan_id, tilldate_max_dpd AS max_dpd_90d
  FROM (
    SELECT *, DATEDIFF(DAY, loan_start_date, full_date) AS days_past_start
    FROM ANALYTICS.LOG.CREDIT_PERFORMANCE_DAILY
    WHERE days_past_start <= 90
    QUALIFY ROW_NUMBER() OVER (PARTITION BY loan_id ORDER BY days_past_start DESC) = 1
  )
)
SELECT l.loan_id, l.user_id, l.disbursed_at, l.vendor,
       loc.loan_application_id, loc.loan_type, loc.loan_num, loc.credit_score, loc.risk_bucket,
       d30.max_dpd_30d, d90.max_dpd_90d,
       IFF(d30.max_dpd_30d >= 4 AND DATEDIFF(DAY, l.disbursed_at::DATE, CURRENT_DATE) >= 30, 1, 0) AS ever4dpd_30d,
       IFF(d90.max_dpd_90d >= 4 AND DATEDIFF(DAY, l.disbursed_at::DATE, CURRENT_DATE) >= 90, 1, 0) AS ever4dpd_90d
FROM loans l
LEFT JOIN loc   ON l.loan_id = loc.loan_id
LEFT JOIN dpd_30 d30 ON l.loan_id = d30.loan_id
LEFT JOIN dpd_90 d90 ON l.loan_id = d90.loan_id;
```

### R5. Application funnel: created → run → offer → disbursed
> Conversion rates per day for any time window.

```sql
WITH apps AS (
  SELECT id AS loan_application_id, user_id, DATE(created_at) AS app_date
  FROM APP_BACKEND.LOAN_SERVICE_PROD.PUBLIC_LOAN_APPLICATIONS_VW
  WHERE created_at >= DATEADD('day', -30, CURRENT_DATE)
),
runs AS (
  SELECT DISTINCT loan_application_id
  FROM APP_BACKEND.LOAN_SERVICE_PROD.PUBLIC_POLICY_RUN_RESULTS_VW
  WHERE updated_at >= DATEADD('day', -30, CURRENT_DATE)
),
offers AS (
  SELECT DISTINCT loan_application_id
  FROM APP_BACKEND.LOAN_SERVICE_PROD.PUBLIC_LOAN_OFFER_VW
  WHERE updated_at >= DATEADD('day', -30, CURRENT_DATE) AND is_active
),
disb AS (
  SELECT DISTINCT loan_application_id
  FROM ANALYTICS.MODEL.LOAN_ORIGINATION_CHARACTERISTICS
  WHERE LOAN_DISBURSED_DATE >= DATEADD('day', -30, CURRENT_DATE)
)
SELECT a.app_date,
       COUNT(*)                                AS apps,
       COUNT(r.loan_application_id)            AS apps_with_run,
       COUNT(o.loan_application_id)            AS apps_with_offer,
       COUNT(d.loan_application_id)            AS apps_disbursed,
       ROUND(COUNT(o.loan_application_id) * 100.0 / NULLIF(COUNT(r.loan_application_id), 0), 1) AS offer_rate_pct,
       ROUND(COUNT(d.loan_application_id) * 100.0 / NULLIF(COUNT(o.loan_application_id), 0), 1) AS disb_rate_pct
FROM apps a
LEFT JOIN runs   r ON a.loan_application_id = r.loan_application_id
LEFT JOIN offers o ON a.loan_application_id = o.loan_application_id
LEFT JOIN disb   d ON a.loan_application_id = d.loan_application_id
GROUP BY 1 ORDER BY 1;
```

### R6. Calib_PD bucket distribution per model version per month (PSI input)
> The shape needed for PSI computation. Used in [v401_audit/src/compute_psi_csi_fy2526.py](v401_audit/src/compute_psi_csi_fy2526.py).

```sql
WITH scores AS (
  SELECT DATE_TRUNC('month', TO_TIMESTAMP(o.value:timestamp::NUMBER / 1000))::DATE AS month,
         m.value:version::STRING                                                    AS model_version,
         m.value:output:Calib_PD::FLOAT                                              AS calib_pd
  FROM APP_BACKEND.LOAN_SERVICE_PROD.PUBLIC_LOAN_OFFER_REQUEST_VW lor,
  LATERAL FLATTEN (input => lor.metadata:scoringServiceOutputHistory) o,
  LATERAL FLATTEN (input => o.value:raw_output:Model_output)           m
  WHERE lor.UPDATED_AT >= '2025-04-01'
    AND m.value:output:Calib_PD IS NOT NULL
)
SELECT month, model_version,
       COUNT(*) AS n,
       AVG(calib_pd) AS mean_pd,
       SUM(IFF(calib_pd < 0.1, 1, 0)) / COUNT(*)::FLOAT AS pct_bin_0_10,
       SUM(IFF(calib_pd BETWEEN 0.1 AND 0.2, 1, 0)) / COUNT(*)::FLOAT AS pct_bin_10_20,
       SUM(IFF(calib_pd BETWEEN 0.2 AND 0.3, 1, 0)) / COUNT(*)::FLOAT AS pct_bin_20_30,
       SUM(IFF(calib_pd BETWEEN 0.3 AND 0.5, 1, 0)) / COUNT(*)::FLOAT AS pct_bin_30_50,
       SUM(IFF(calib_pd > 0.5, 1, 0)) / COUNT(*)::FLOAT AS pct_bin_50_plus
FROM scores
GROUP BY 1, 2 ORDER BY 1, 2;
```

### R7. Dormant whitelist + last BRE run
> Whitelisted users who actually applied recently.

```sql
WITH wl AS (
  SELECT DISTINCT kb_id, whitelisted_cohort, whitelist_type
  FROM ANALYTICS.LONGTERM.LENDING_DORMANT_WHITELISTED_BASE
)
SELECT wl.kb_id, wl.whitelisted_cohort,
       MAX(prr.updated_at) AS last_bre_run,
       COUNT(prr.id)       AS bre_runs_last_30d
FROM wl
LEFT JOIN APP_BACKEND.LOAN_SERVICE_PROD.PUBLIC_LOAN_APPLICATIONS_VW la
  ON wl.kb_id = la.user_id
LEFT JOIN APP_BACKEND.LOAN_SERVICE_PROD.PUBLIC_POLICY_RUN_RESULTS_VW prr
  ON la.id = prr.loan_application_id
 AND prr.updated_at >= DATEADD('day', -30, CURRENT_DATE)
GROUP BY 1, 2;
```

---

## Final dbt grain reminder

`ANALYTICS.MODEL.UW_DECISION` is one row per
**`(loan_application_id, policy_run_date, model_version)`** — the latest BRE
re-run per app per day per model. Every row carries decision context, model
scores, offer outcome, and (if disbursed) early DPD flags.

When in doubt: the dbt model itself is the **executable** version of this
reference doc — see [Untitled 3.sql](Untitled%203.sql).
