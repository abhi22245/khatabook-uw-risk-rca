# UW Risk RCA — Jul–Aug 2026 cohort deterioration

**Status:** live investigation · **Branch:** `abhi_rca` · **Last updated:** 2026-09-11
**Artifact (findings dashboard):** https://claude.ai/code/artifact/07e5d5ba-77a7-478a-ae8e-9f198451dbe8

> **If you are a new session picking this up cold: read [§1](#1-what-we-are-doing),
> [§2](#2-how-to-run-a-query) and [§5](#5-traps-that-will-silently-corrupt-your-numbers)
> before writing any SQL.** §5 in particular — four of those six traps produce
> plausible-looking wrong numbers rather than errors.

---

## 1. What we are doing

Finding out **which lending cohorts got riskier in 1 July – 10 August 2026**, and why.

The measure of risk is **ECL** (expected credit loss) as a % of disbursed amount.
Loans are split into four mutually exclusive cohorts: **Fresh**, **Renewal**,
**Dormant**, **AA**.

The work is running step by step, the user directing each step. Every figure must
be reproducible from a committed query — the user verifies independently, so a
number without a query behind it is not deliverable.

### Where we've got to

1. Cohort-level disbursals + ECL for the window → **Renewal is the cohort that deteriorated**
2. Ruled out loan seasoning as the explanation
3. Split each cohort by `experiment_type` → **one experiment dominates Renewal's loss**
4. Loan-level drill into that experiment → **not a few bad loans; it's selection**
5. Lender split of that experiment → **it's the policy, not a lender**
6. Monthly attribution of the July move → **the experiment did *not* cause it; lender
   turnover plus a broad unexplained drift did**

> **Read §6.6 before acting on §6.3–6.5.** Those sections identify a genuinely bad experiment,
> but §6.6 shows it accounts for only ~6% of what changed in July. Both are true; they answer
> different questions — *where is the loss* vs *what changed*.

Full numbers in [§6](#6-findings-so-far). Open threads in [§8](#8-open-threads--next-steps).

---

## 2. How to run a query

```bash
cd ~/Desktop/RISK_RCA
python3 tools/run_query.py queries/Q1_cohort_disbursals_ecl.sql
python3 tools/run_query.py queries/Q6_overrule_bucket_b_loan_level.sql --csv data/out.csv
```

### Auth — read this before debugging a connection failure

Snowflake **deprecated password authentication around 10 Sep 2026**. Any connection
using `password=` now fails with:

```
250001 (08001): ... Incorrect username or password was specified.
```

**That error almost never means a wrong password — it means the code is still on
password auth.** Do not rotate the password to "fix" it.

| | |
|---|---|
| Method | RSA key-pair (unencrypted PKCS8 PEM) |
| Key file | `~/.snowflake/rsa_key_sf_ds.p8` (chmod 600) — **never commit or print it** |
| Env var | `SNOWFLAKE_PRIVATE_KEY_FILE` |
| User / role | `datascience` / `DATA_SCIENCE` |
| Account | `ao58354.ap-south-1.aws` |
| Warehouse | `DS_FREQUENT_LOAD_WH` (fallback `DS_ADHOC_LOAD_CLUSTER_WH`), override with `$SF_WH` |
| Full guide | `~/Desktop/SNOWFLAKE_KEYPAIR_AUTH_README.md` |

Known-stale: `ds_rca_repo/.env` has `SNOWFLAKE_AUTHENTICATOR=snowflake` and a dead
password; `ds_rca_repo/kg/config.py` still builds a `password=` kwarg. Anything
importing that config will fail until migrated. `tools/run_query.py` is already on
key-pair — use it.

The Snowflake **MCP server** (`ANALYTICS.ADHOC.CLAUDE_MCP_SERVER`) does not connect
in this environment. Use the runner script, not MCP.

---

## 3. The data model

Three tables carry the whole analysis. `UW_DCN_TABLES_REFERENCE.md` in this repo
documents the 8 tables behind `uw_decision_monitoring`; the joins actually used here are:

| Table | Grain | What we take from it |
|---|---|---|
| `analytics.model.loan_origination_characteristics` (LOC) | one row per **disbursed loan** (`LOAN_ID`) | **The spine.** Loan counts, `LOAN_AMOUNT`, `LOAN_DISBURSED_DATE`, `EXPERIMENT_TYPE`, `LAST_LOAN_MAX_EVER_DPD`, credit score, lender, geography |
| `analytics.model.uw_decision_monitoring` | one row per `(loan_application_id, policy_run_date, model_version)` | Cohort flags: `IS_FRESH`, `IS_RENEWAL`, `IS_DORMANT_FLAG`, `COMBINATION_TYPE` |
| `analytics.MODEL.LOAN_ECL_METRICS` | one row per `(loan_id, BOM)` | `ECL_PORTFOLIO`, plus `MOB`, `ACTUAL_DPD_V2`, `MAX_EVER_DPD`, `PRINCIPAL_OUTSTANDING_V2`, `LGD` |

**Loan counts come from LOC, never from `uw_decision_monitoring`** — that table is at
model-arm grain and counting loans off it multiplies every loan by its arms and re-runs.

The canonical skeleton (every query here uses it):

```sql
WITH ecl AS (
    SELECT a.LOAN_ID, a.ECL_PORTFOLIO AS m0_ecl
    FROM analytics.MODEL.LOAN_ECL_METRICS a
    WHERE a.BOM = (SELECT MAX(BOM) FROM analytics.MODEL.LOAN_ECL_METRICS)
    QUALIFY ROW_NUMBER() OVER (PARTITION BY a.LOAN_ID ORDER BY a.BOM DESC) = 1
),
uw AS (
    SELECT LOAN_ID, IS_FRESH, IS_RENEWAL, IS_DORMANT_FLAG, COMBINATION_TYPE
    FROM analytics.model.uw_decision_monitoring
    WHERE MODEL_VERSION = MODEL_VERSION_FINAL AND LOAN_ID IS NOT NULL
    QUALIFY ROW_NUMBER() OVER (PARTITION BY LOAN_ID ORDER BY POLICY_RUN_DATE DESC) = 1
)
SELECT ...
FROM analytics.model.loan_origination_characteristics loc
LEFT JOIN uw  ON loc.LOAN_ID = uw.LOAN_ID
LEFT JOIN ecl e ON loc.LOAN_ID = e.LOAN_ID
WHERE loc.LOAN_DISBURSED_DATE >= '2026-07-01'
  AND loc.LOAN_DISBURSED_DATE <  '2026-08-11'
```

Verified no fan-out (see [§5](#5-traps-that-will-silently-corrupt-your-numbers), trap 1):
LOC in window = 17,512 rows / 17,512 distinct loans; after both LEFT JOINs, still 17,512.

### Cohort definition

Evaluated **in this order**, so each loan lands in exactly one cohort:

```sql
CASE WHEN uw.LOAN_ID IS NULL         THEN 'Unmapped'   -- 0 loans in this window
     WHEN uw.COMBINATION_TYPE = 'AA' THEN 'AA'
     WHEN uw.IS_DORMANT_FLAG = 1     THEN 'Dormant'
     WHEN uw.IS_RENEWAL = 1          THEN 'Renewal'
     ELSE 'Fresh' END AS cohort
```

**The ordering is a choice, not a fact.** Dormant is not a third population — it
overlaps both Fresh and Renewal. Raw 2×2 for this window:

| LOC `LOAN_TYPE` | `IS_DORMANT_FLAG` | Loans |
|---|---|---|
| Fresh | 0 | 8,121 |
| Renewal | 0 | 5,630 |
| Fresh | 1 | 2,813 |
| Renewal | 1 | 948 |

Because dormancy is tested first, **"Fresh" here means _fresh and not dormant_**.
Put fresh/renewal ahead of dormant instead and you get Fresh 10,550 / Renewal 6,578 /
Dormant 0 — same total, completely different story. We use dormancy-first because
that is how the dashboards segment, and it is the only ordering under which Dormant
is a cohort at all.

Reconciliation to the published numbers (AA carved out first):

| | All | − AA | = Published |
|---|---|---|---|
| Fresh (non-dormant) | 8,121 | 384 | **7,737** |
| Renewal (non-dormant) | 5,630 | 320 | **5,310** |
| Dormant (2,813 + 948) | 3,761 | 222 | **3,539** |
| AA | — | — | **926** |
| | | | **17,512** |

Cross-check: LOC's own `LOAN_TYPE` agrees with `uw.IS_RENEWAL` on **every loan** —
zero disagreement.

---

## 4. ECL: which column, and the dbt change

**Use `analytics.MODEL.LOAN_ECL_METRICS.ECL_PORTFOLIO`.** Not `M0_ECL`, and not the
older `RISK_M0_MODEL_ECL_PREDICTIONS.FINAL_ECL_PRED * 0.88`.

`uw_decision_monitoring.sql` in this repo has been updated (commit `90c894f`): a
`risk_cte` on `LOAN_ECL_METRICS` projecting `ECL_PORTFOLIO` aliased as `m0_ecl` so
~79 downstream references keep working. **The 0.88 haircut does not carry over** —
`ECL_PORTFOLIO` is already the final figure.

> ⚠️ **The deployed table is still on the old source.** `analytics.model.uw_decision_monitoring.M0_ECL`
> in production matches `ECL_PORTFOLIO` on only 44,243 of 158,970 loans (27.8%) and runs
> **~16% low** on average (5,995.63 vs 7,161.00). Until the dbt model is redeployed, do
> **not** read ECL off `uw_decision_monitoring` — go to `LOAN_ECL_METRICS` directly, as
> every query here does. Re-check with `Q3`.

Also note: this repo's `uw_decision_monitoring.sql` is an **older fork** than the copy in
`~/Desktop/ds_rca_repo/`. That copy additionally has the `created_at` migration (this one
still uses `updated_at`), `lender_reassignment_flag`, and the Low & Grow join — and still
has the *old* ECL source. Reconcile before deploying either.

---

## 5. Traps that will silently corrupt your numbers

Every one of these was hit and verified. Four produce wrong numbers rather than errors.

**1. `LOAN_ECL_METRICS` has triplicate rows.** The 2026-09-01 BOM holds 390,223 rows for
320,598 distinct loans — 285,736 loans appear once, 99 twice, and **34,763 three times**
with identical ECL. The `QUALIFY ROW_NUMBER() ... = 1` is load-bearing; without it those
loans' loss counts 3×. (Only 3 loans in the whole snapshot have differing ECL across
their rows, so which row you keep doesn't matter — that you keep only one does.) → `Q4`

**2. BOM must be `MAX(BOM)`, never `DATE_TRUNC('MONTH', CURRENT_DATE)`.** The current
month has no BOM row until the monthly ECL job runs, so on the 1st of a month the
calendar-month filter matches nothing and every ECL comes back NULL. Latest available
is **2026-09-01**. (There are also 3 rows with a NULL BOM; `MAX()` ignores them.)

**3. `uw_decision_monitoring` must be filtered to the allocated arm.** Without
`MODEL_VERSION = MODEL_VERSION_FINAL`, each BRE run's several model-arm rows fan out
and inflate loan counts.

**4. AA must be carved out first.** Per KB rule L14, leaving `COMBINATION_TYPE = 'AA'`
in double-counts across Fresh/Renewal/Dormant.

**5. `EXPERIMENT_TYPE` ≠ `EXPERIMENT_TYPE_FINAL`.** Use LOC's `EXPERIMENT_TYPE`. It
agrees with `LOAN_ECL_METRICS.EXPERIMENT_TYPE` on all 17,512 loans, zero NULLs, 47
distinct values. `EXPERIMENT_TYPE_FINAL` is a normalised rollup that differs on **5,123
loans (29%)**, collapsing `NORMAL LOAN`, `1 BOUNCE POLICY`, `2 BOUNCE POLICY` into
`BAU` — which would merge the largest low-risk bucket with three others.

**6. Seasoning confounds cross-month comparisons.** All ECL comes from one BOM snapshot,
so July loans carry ~2 months of performance and January loans ~8. Comparing one cohort
across months inherits that. **Control for it by comparing cohorts _within_ a month** —
see the Fresh−Renewal spread in [§6.2](#62-it-is-not-a-seasoning-artifact).

Two smaller ones:

- `LOAN_DISBURSED_DATE` may carry a time component. Use a half-open interval
  (`>= '2026-07-01' AND < '2026-08-11'`), not `BETWEEN ... AND '2026-08-10'`, which
  silently drops most of 10 Aug.
- `is_dormant_flag` here is the **dashboard** definition (BRE input flag with a whitelist
  fallback), *not* the live routing dormancy (flag AND isFresh). They disagree for some
  users — see `WARN_dormant_flag_definition` in the ds_rca_repo knowledge base.

---

## 6. Findings so far

### 6.1 Cohort-level — Renewal is the cohort that deteriorated

Window totals (`Q1`). ECL coverage 100%; no unmapped loans.

| Cohort | Loans | Disbursed ₹Cr | Avg ticket ₹ | ECL ₹Cr | ECL % | vs Jan–Jun 2026 |
|---|---|---|---|---|---|---|
| Fresh | 7,737 | 86.96 | 112,390 | 4.25 | 4.89 | above 2 of 6 months |
| **Renewal** | 5,310 | 106.52 | 200,601 | 4.37 | **4.10** | **above all 6 months** |
| Dormant | 3,539 | 47.99 | 135,600 | 2.07 | 4.32 | above 5 of 6 months |
| AA | 926 | 14.28 | 154,163 | 0.65 | 4.58 | above 2 of 6 months |
| **All** | **17,512** | **255.74** | **146,036** | **11.35** | **4.44** | |

**The cohort with the highest loss rate is not the cohort that got worse.** Fresh carries
the highest rate (4.89%) but four of its six prior months were worse — that is normal for
Fresh. Renewal at 4.10% is above *every* month of 2026; its previous worst was 3.88%
(January) and June was 3.04%.

Monthly ECL % by cohort (`Q2`), Aug = 1–10 only:

| Month | Fresh | Renewal | Dormant | AA |
|---|---|---|---|---|
| Jan | 4.72 | 3.88 | 5.24 | 5.00 |
| Feb | 4.92 | 3.80 | 3.87 | 4.65 |
| Mar | 5.34 | 3.64 | 3.95 | 5.17 |
| Apr | 5.19 | 3.60 | 4.14 | 4.59 |
| May | 5.01 | 3.81 | 4.17 | 4.04 |
| Jun | 4.39 | 3.04 | 3.56 | 3.55 |
| **Jul** | 4.84 | **4.15** | 4.24 | 4.59 |
| **Aug\*** | 5.06 | 3.91 | 4.57 | 4.52 |

Volume moved at the same time: the window ran 427 disbursals/day against June's 333
(+28%). Monthly loan counts went Fresh 4,290→6,024, Renewal 3,138→4,174, Dormant
1,919→2,695 into July (all roughly +37%).

### 6.2 It is not a seasoning artifact

The obvious objection to §6.1 is trap 6 — younger loans, less performance. The
**Fresh − Renewal ECL spread** controls for it: both cohorts sit in the same month with
the same seasoning, so anything that moves the gap between them is real.

| Jan | Feb | Mar | Apr | May | Jun | **Jul** | Aug\* |
|---|---|---|---|---|---|---|---|
| 0.84 | 1.12 | 1.70 | 1.59 | 1.20 | 1.35 | **0.69** | 1.15 |

Fresh normally runs 0.84–1.70 pp riskier than Renewal. In July that collapses to
**0.69 pp — the narrowest of the year** — then reopens to 1.15 pp in August. Seasoning
moves both cohorts together and cannot close the gap between them. So July's compression
is Renewal deteriorating, and it looks like a **July-specific event** rather than a new
run rate.

### 6.3 Renewal by experiment type — one experiment dominates

`Q5`, 33 experiment types in Renewal. Ranked by **excess ECL** = rupees of loss above
what the bucket would carry at Renewal's own 4.10% rate (raw ECL ₹ just ranks by size).

| Experiment type | Loans | ECL ₹Cr | ECL % | Excess ₹Cr |
|---|---|---|---|---|
| **POLICY RULES OVERRULE RISK BUCKET B POLICY** | 500 | 0.774 | **7.35** | **+0.342** |
| 5 Lakh ATS Experiment | 44 | 0.145 | 7.08 | +0.061 |
| POLICY RULES OVERRULE RISK BUCKET C POLICY | 42 | 0.072 | 8.62 | +0.038 |
| Tenure Experiment: Risk Bucket B | 51 | 0.075 | 8.20 | +0.037 |
| … 25 more … | | | | |
| POLICY RULES OVERRULE POLICY | 714 | 0.471 | 3.19 | −0.135 |
| NORMAL LOAN | 1,695 | 0.890 | 3.15 | −0.270 |

`POLICY RULES OVERRULE RISK BUCKET B POLICY` holds **9.4% of Renewal's loans but 17.7%
of its ECL** — ₹0.342 Cr excess, 5.6× the next contributor. The plain `NORMAL LOAN` book,
a third of the cohort, runs at 3.15%. **The BAU renewal book is not the problem.**

The pattern generalises — every experiment overruling into **risk bucket B or C** runs
hot, and the bucket-A equivalent does not:

| Grouping | Loans | % of cohort loans | ECL ₹Cr | % of cohort ECL | ECL % |
|---|---|---|---|---|---|
| Risk bucket **B/C** overrule family (6 experiments) | 706 | 13.3 | 1.036 | **23.7** | **7.48** |
| NPS POLICY OVERRULE RISK BUCKET **A** | 212 | 4.0 | 0.120 | 2.7 | 4.22 |
| Renewal, all types | 5,310 | 100.0 | 4.370 | 100.0 | 4.10 |

The six: `POLICY RULES OVERRULE RISK BUCKET B POLICY`, `POLICY RULES OVERRULE RISK BUCKET
C POLICY`, `Tenure Experiment: Risk Bucket B`, `Tenure Experiment: Risk Bucket C`,
`NPS Experiment: Risk Bucket B`, `NPS POLICY OVERRULE RISK BUCKET B`. An eighth of
Renewal's loans, nearly a quarter of its loss. **Whatever is wrong is specific to
overruling into B and C, not to overruling as such.**

### 6.4 Inside the 500 — not a few bad loans; it's selection

`Q6` → `data/renewal_overrule_bucket_b_500_loans.csv` (500 rows × 28 cols). **Not in git**
— see [§7](#7-repo-contents); regenerate it with the command there.

**Concentration — the loss is broad-based, and the control proves it.**

⚠️ **Methodological note.** The first version of this compared the 500 against a
*perfectly-even* loss distribution. That is the wrong benchmark — every credit book is
skewed (ECL scales with both loan size and risk), so no real portfolio sits near it, and
"16% of loans hold half the loss" means nothing on its own. The right benchmark is a
**healthy bucket in the same cohort and window**. Corrected 2026-09-12.

| Renewal bucket | Loans | ECL % | Worst 2% hold | Worst 10% hold | Half the loss in | Gini |
|---|---|---|---|---|---|---|
| NORMAL LOAN | 1,695 | 3.15 | 24.0% | 48.8% | 11% of loans | 0.652 |
| OVERRULE POLICY | 714 | 3.19 | 18.6% | 44.3% | 13% of loans | 0.594 |
| **OVERRULE RISK BUCKET B** | 500 | **7.35** | 11.7% | 37.3% | 16% of loans | **0.533** |
| *if every loan lost the same* | — | — | 2.0% | 10.0% | 50% of loans | 0.000 |

**Concentration runs opposite to loss rate.** The two healthy buckets sit at ~3.2% ECL
with *high* concentration — a small bad tail on a clean book, which is what a working
credit policy looks like. The overrule bucket has more than double the loss rate and the
**lowest** concentration of the three. There is no tail to remove; the book is worse all
the way through.

Loan-level ECL %: median **4.74** (already above Renewal's 4.10), p75 8.37, p90 15.12,
p99 45.42, max 67.91. The *median* loan being above the cohort average is the clinching
number — in a few-blow-ups book the median looks fine and only the tail is ugly.

**They are already failing at MOB 1–2.** All 500 loans are 1–2 months on book at the
snapshot:

| Renewal bucket | Loans | ECL % | Ever DPD>0 | Ever 4+ DPD | Currently DPD | Avg prior-loan max DPD |
|---|---|---|---|---|---|---|
| **OVERRULE RISK BUCKET B** | 500 | **7.35** | **80.4%** | **20.0%** | **31.8%** | **4.05** |
| NORMAL LOAN | 1,695 | 3.15 | 50.5% | 5.1% | 9.1% | 1.90 |
| OVERRULE POLICY | 714 | 3.19 | 59.4% | 8.8% | 16.1% | 2.30 |
| All other Renewal | 2,401 | 4.22 | 58.6% | 7.3% | 14.2% | 2.26 |

**And they were selected that way.** Split by the previous loan's max-ever DPD
(control = the 4,810 Renewal loans not in this experiment):

| Prior loan max DPD | Overrule B loans | share | ECL % | Control loans | share | ECL % |
|---|---|---|---|---|---|---|
| 0 (clean) | 1 | 0.2% | 4.26 | 596 | 12.4% | 2.63 |
| 1–3 | 229 | 45.8% | **5.76** | 3,364 | 69.9% | 3.35 |
| 4–10 | 270 | **54.0%** | **8.62** | 821 | 17.1% | 5.97 |
| 11–30 | 0 | — | — | 28 | 0.6% | 8.34 |
| **All** | 500 | 100% | **7.35** | 4,810 | 100% | **3.75** |

Two things are wrong and they compound:

- **Mix** — 54% of the bucket comes from the 4–10 prior-DPD band vs 17% for the control,
  and just **1 of 500 loans has a clean prior loan** (vs 12.4%).
- **Performance within band** — even holding prior DPD fixed, these run 1.4–1.7× worse
  (5.76 vs 3.35 at 1–3; 8.62 vs 5.97 at 4–10).

So this **cannot** be written off as "we knowingly took 4–10 DPD borrowers and priced for
it". Something beyond prior DPD is being given up when this policy is overruled. The
11–30 band is correctly blocked — the leak is entirely in **4–10**.

### 6.5 Lender split inside the 500 — it's the policy, not a lender

`Q8`. Volume is concentrated: **VIVRITI 203 loans (40.6%)** and **Western Capital 158
(31.6%)** are 72.2% of the bucket. Loss is not — their loss share is 73.1%, i.e. exactly
proportional to volume.

Each lender is measured **against itself**: the same lender's Renewal loans, same window,
that went through any *other* experiment. That separates "risky lender" from "this policy
is bad at this lender".

| Lender | Loans | % of 500 | ECL % | Control loans | Control ECL % | Lift pp |
|---|---|---|---|---|---|---|
| VIVRITI | 203 | 40.6 | 7.27 | 1,313 | 3.06 | **+4.21** |
| Western Capital | 158 | 31.6 | 7.53 | 537 | 5.40 | +2.13 |
| SMICC | 44 | 8.8 | 6.17 | 756 | 2.85 | +3.32 |
| CAPRION | 28 | 5.6 | 8.14 | 630 | 5.80 | +2.35 |
| JUPITER | 26 | 5.2 | 8.42 | 493 | 3.40 | **+5.02** |
| SLICE | 23 | 4.6 | 5.51 | 832 | 2.96 | +2.55 |
| CASHTREE | 17 | 3.4 | 9.67 | 143 | 5.98 | +3.69 |
| NIYOGIN_APOLLO | 1 | 0.2 | 0.34 | 11 | 3.61 | −3.27 *(1 loan, ignore)* |
| **All** | **500** | **100** | **7.35** | **4,810** | **3.75** | **+3.60** |

**Every lender is worse inside the experiment**, by +2.13 to +5.02 pp. Lenders do carry
different baseline risk (SMICC 2.85% vs CASHTREE 5.98% on their other Renewal loans), and
the experiment adds loss on top of *all* of them.

Measured as excess against the bucket's own 7.35%, the largest single-lender contribution
is **₹0.009 Cr** — noise. **No lender is dragging this bucket**, and routing away from one
would not fix it: the policy produces the same bad book wherever it is sent. This is
consistent with §6.4 — broad-based, not concentrated.

### 6.6 The overrule bucket did NOT cause the July move — lender turnover did

`Q9`, `Q10`. **This overturns the direction §6.3–6.5 was pointing.** Those sections show the
bucket is lossy; they never showed it *changed* in July, which is what would make it the
cause. Tracked monthly back to Apr 2025 (ECL coverage verified 100% every month, so no
survivorship bias), it doesn't.

**Decomposition of Renewal's +1.11 pp June→July move:**

| Component | pp | Share |
|---|---|---|
| New / surged lenders (CAPRION, Western Capital) | **+0.52** | **47%** |
| Broad drift across continuing lenders | **+0.52** | **47%** |
| Overrule risk bucket B growing its excess | **+0.07** | **6%** |
| **Total** | **+1.11** | 100% |

**The bucket is a slow burn, not a July event.** Its share of Renewal fell through 2026 to a
7.1% low in June and rose to 8.7% in July — but it ran 13–16% through most of 2025, so July
is unremarkable. What *has* moved is its lift over the rest of the cohort, widening every
month of 2026:

| Month | Bucket loans | Share of Renewal | Bucket ECL % | Rest ECL % | Lift pp | Contribution pp |
|---|---|---|---|---|---|---|
| Aug 2025 | 403 | 15.6% | 5.11 | 4.13 | +0.98 | 0.150 |
| Nov 2025 | 315 | 12.5% | 5.77 | 3.51 | +2.26 | 0.289 |
| Feb 2026 | 252 | 9.7% | 5.90 | 3.57 | +2.32 | 0.228 |
| May 2026 | 231 | 7.7% | 6.32 | 3.58 | +2.74 | 0.223 |
| Jun 2026 | 224 | 7.1% | 6.02 | 2.78 | +3.24 | 0.266 |
| Jul 2026 | 365 | 8.7% | 7.33 | 3.82 | **+3.51** | 0.333 |
| Aug 2026* | 135 | 11.9% | 7.42 | 3.46 | **+3.96** | 0.450 |

`lift_pp` is the seasoning-immune column — both sides share a month, vintage and BOM
snapshot, so only a real change in relative quality moves it. Compare `ecl_pct` down a
column only loosely (trap 6). Full series in `Q9`.

**What actually changed: the lender panel turned over.** Non-bucket Renewal, June vs July:

| Lender | Jun loans | Jun ECL % | Jul loans | Jul ECL % | % of Jul book |
|---|---|---|---|---|---|
| **CAPRION** | 18 | 5.59 | **499** | **6.20** | 12.2% |
| **Western Capital** | **0** | — | **296** | **5.77** | 8.5% |
| VIVRITI | 940 | 2.55 | 1,078 | 3.07 | 27.8% |
| SLICE | 692 | 2.51 | 644 | 3.15 | 18.4% |
| SMICC | 624 | 2.82 | 628 | 2.93 | 15.6% |
| JUPITER | 342 | 3.34 | 435 | 3.41 | 12.8% |
| CASHTREE | 122 | 3.50 | 143 | 5.98 | 3.7% |
| LENDBOX | 117 | 2.76 | 83 | 2.42 | 0.9% |
| **NIYOGIN** *(exited)* | 59 | 4.38 | **0** | — | 0.0% |

- **CAPRION**: 18 → 499 Renewal loans, a 28× jump, at 6.20%.
- **Western Capital**: **zero** Renewal loans in June, 296 in July at 5.77% plus 75 inside the
  overrule bucket. A brand-new counterparty, not an expansion — which also means its Q8
  "control" baseline (§6.5) is its own first six weeks, so read that lift cautiously.
- **NIYOGIN**: 12 months in the experiment, stopped entirely after June. `NIYOGIN_APOLLO`
  appears in Aug with 1 loan — likely a re-onboarding, **worth confirming**.

Newcomers wrote **20.8% of July's non-bucket Renewal disbursal at 6.01% ECL, vs 3.24% for
lenders already there**.

**Still unexplained:** the other ~47%. Every continuing lender drifted up at once — VIVRITI
2.55→3.07, SLICE 2.51→3.15, CASHTREE 3.50→5.98. A simultaneous drift across unrelated
counterparties usually points upstream of any single lender or experiment.

---

## 7. Repo contents

```
README.md                         this file
uw_decision_monitoring.sql        the dbt model (ECL source updated, commit 90c894f)
UW_DCN_TABLES_REFERENCE.md        reference for the 8 tables behind uw_decision_monitoring
xgb_feature_list_combined_features_v5.0.0.csv
                                  360 v5 model features across 6 modules
                                  (SMS 128, BUREAU 75, Transaction 46, PERFORMANCE 42,
                                   LOCATION 35, ACTIVITY 34)
cohort_risk_jul_aug.html          the findings artifact (published, see top of file)
tools/run_query.py                Snowflake runner (key-pair auth)
queries/                          every number in §6 comes from these
data/                             query exports — GITIGNORED, see below
```

### `data/` is deliberately not in this repo

Loan-level exports contain real loan IDs, amounts, credit scores, DPD history and
geography, so `data/` is gitignored and was stripped from git history before this repo
was pushed. Nothing is lost — anyone with Snowflake access regenerates any export in one
command:

```bash
python3 tools/run_query.py queries/Q6_overrule_bucket_b_loan_level.sql \
    --csv data/renewal_overrule_bucket_b_500_loans.csv
```

Keep it that way: put new loan-level pulls under `data/`, and never commit credentials or
the Snowflake RSA key.

### Query inventory

| Query | What it answers | Produces |
|---|---|---|
| `Q1_cohort_disbursals_ecl.sql` | Cohort-wise loans + ECL for the window | §6.1 table |
| `Q2_cohort_monthly_trend.sql` | Monthly loans + ECL % by cohort, Jan–10 Aug | §6.1 monthly table, §6.2 spread |
| `Q3_verify_deployed_ecl_source.sql` | Is the deployed table on `ECL_PORTFOLIO` yet? | §4 warning — **re-run before trusting `uw_decision_monitoring.M0_ECL`** |
| `Q4_ecl_duplicate_check.sql` | Duplicate rows per loan in the latest BOM | §5 trap 1 |
| `Q5_cohort_experiment_type_ecl.sql` | `experiment_type` × cohort: loans, ECL, excess ECL | §6.3. Returns **all four cohorts** (150 rows) |
| `Q6_overrule_bucket_b_loan_level.sql` | The 500 loans, loan by loan | §6.4. Writes `data/renewal_overrule_bucket_b_500_loans.csv` — **gitignored**, regenerate locally |
| `Q7_concentration_vs_control.sql` | Loan-level ECL for the 500 + two healthy control buckets | §6.4 concentration table. Compute the curve / Gini downstream |
| `Q8_overrule_bucket_b_by_lender.sql` | Lender split of the 500, each lender vs its own other-experiment baseline | §6.5 |
| `Q9_overrule_bucket_b_monthly.sql` | Bucket share + seasoning-immune lift, monthly Apr 2025 → Aug 2026 | §6.6. **Read `lift_pp`, not `ecl_pct`, across months** |
| `Q10_overrule_bucket_b_lender_by_month.sql` | Lender entry/exit inside the bucket, with NEW/EXITED/CONTINUING status | §6.6 |

Two notes on the CSV: `calib_pd` comes back as the string `null` and `risk_bucket_final`
is JSON-quoted (`"B"`) — artefacts of VARIANT extraction upstream in
`uw_decision_monitoring`, not missing data. Cast before filtering.

### Conventions for adding to this repo

- One query per finding, numbered `Q<n>_<slug>.sql`, committed **before** the finding is
  reported. Header comment states what it answers, which column choices were made and why,
  and any verification run against it.
- Reuse the §3 skeleton so cohort definitions stay identical across queries.
- New findings go in §6 as a new subsection; update §1 "where we've got to" and §8.
- Record disproved hypotheses too (§8) — knowing 11–30 prior DPD is correctly blocked is
  worth as much as knowing 4–10 isn't.

---

## 8. Open threads / next steps

Named by the user for upcoming sessions:

1. ~~**Lender split within an experiment**~~ — **done, §6.5.** VIVRITI + Western Capital are
   72.2% of the 500, but loss tracks volume and *every* lender is +2.13 to +5.02 pp worse
   inside the experiment. It is the policy, not a lender.
2. **Experiment types in the other cohorts** — `Q5` already returns Fresh, Dormant and AA
   (150 rows total); only Renewal has been read. Fresh is the largest book and its
   experiment split is unexamined.
3. **Deeper cuts on an experiment** — geography, credit score band, ticket size, tenure,
   `model_version_final`.

Analytically open:

4. ~~**Did the B/C overrule family grow in July?**~~ — **answered, §6.6. No.** It contributes
   ~6% of the move. It is a standing, steadily worsening problem, not the July cause.
   **The July cause is ~47% new-lender entry and ~47% broad drift across continuing
   lenders, and that broad drift is now the biggest open question.** A simultaneous rise
   across unrelated counterparties points upstream — a scoring, policy or population change
   that hit everyone at once. Start there.
5. **Why do these loans underperform _within_ prior-DPD band?** (§6.4) Prior DPD does not
   explain the 1.4–1.7× gap. What else does the overruled policy screen on?
5b. **Confirm the NIYOGIN → NIYOGIN_APOLLO relationship** (§6.6). If it is a re-onboarding
   of the same counterparty, NIYOGIN's exit is not a true exit and the July lender
   attribution shifts slightly.
6. **Dormant** is above five of six prior months and still climbing into August
   (4.57%) — second-order but unexplained.
7. **Fresh** has had no experiment-type drill at all.

Housekeeping:

8. Redeploy `uw_decision_monitoring` so the deployed `M0_ECL` carries `ECL_PORTFOLIO`
   (§4), and reconcile this repo's fork against `ds_rca_repo`'s newer copy.

### Standing caveats on everything above

- **August is 10 days** (3,842 loans), not a month. Directional only.
- All ECL is one snapshot, **BOM 2026-09-01**. Re-running later moves every number.
- Cohort ordering is a modelling choice (§3).
