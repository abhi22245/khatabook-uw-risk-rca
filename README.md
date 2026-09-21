# UW Risk RCA — Jul–Aug 2026 cohort deterioration

**Status:** live investigation · **Branch:** `abhi_rca` · **Last updated:** 2026-09-21
**Artifact (findings dashboard):** https://claude.ai/artifact/1yZkaeiaCFfHZhhTBdszTq

> **If you are a new session picking this up cold: read [§1](#1-what-we-are-doing),
> [§2](#2-how-to-run-a-query) and [§5](#5-traps-that-will-silently-corrupt-your-numbers)
> before writing any SQL.** §5 in particular — five of those seven traps produce
> plausible-looking wrong numbers rather than errors.

---

## 1. What we are doing

Finding out **which lending cohorts got riskier in 1 July – 20 August 2026**, and why.

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

### A word on "bucket"

The word is overloaded in this domain. Throughout this file:

| Term | Means |
|---|---|
| **risk bucket B / C** | a **risk grade** the model assigns (`KB-B` in `RISK_BUCKET`) |
| **the OVERRULE-B experiment** | the experiment type `POLICY RULES OVERRULE RISK BUCKET B POLICY` — the policy that overrules the rule for grade-B renewals |
| **the 610** | the loans in that experiment, Renewal cohort, 1 Jul – 20 Aug 2026 (was "the 500" when the window ended 10 Aug) |

Never write bare "bucket" for the experiment — say "the OVERRULE-B experiment".

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
  AND loc.LOAN_DISBURSED_DATE <  '2026-08-21'
```

Verified no fan-out (see [§5](#5-traps-that-will-silently-corrupt-your-numbers), trap 1):
LOC in window = 22,546 rows / 22,546 distinct loans; after both LEFT JOINs, still 22,546.

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
| Fresh | 0 | 10,542 |
| Renewal | 0 | 7,094 |
| Fresh | 1 | 3,676 |
| Renewal | 1 | 1,234 |

Because dormancy is tested first, **"Fresh" here means _fresh and not dormant_**.
Put fresh/renewal ahead of dormant instead and you get Fresh 13,717 / Renewal 7,958 /
Dormant 0 — same total, completely different story. We use dormancy-first because
that is how the dashboards segment, and it is the only ordering under which Dormant
is a cohort at all.

Reconciliation to the published numbers (AA carved out first):

| | All | − AA | = Published |
|---|---|---|---|
| Fresh (non-dormant) | 10,542 | 501 | **10,041** |
| Renewal (non-dormant) | 7,094 | 390 | **6,704** |
| Dormant (3,676 + 1,234) | 4,910 | 280 | **4,630** |
| AA | — | — | **1,171** |
| | | | **22,546** |

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

**0. The BOM snapshot moves — your numbers will drift between sessions.**
The 2026-09-01 BOM was written incrementally: 390,223 rows / 320,598 loans on 11 Sep,
530,648 / 321,971 by 15 Sep, and **324,907 / 324,907 by 21 Sep with the duplicates
removed**. The `QUALIFY` dedup absorbed all of it — Q1 re-ran bit-identical throughout —
but **older vintages did shift** (April 2026 rest-of-Renewal moved 3.39 → 3.43). Re-run
before quoting a figure, never assume a number from a previous session holds, and date
every result. A new BOM will move everything again.

**1. `LOAN_ECL_METRICS` had duplicate rows (3 per loan on 11 Sep, 7 by 15 Sep, now none).**
Through mid-September the 2026-09-01 BOM held up to 7 identical rows for each of 34,763
loans. It has since been cleaned to one row per loan. **Keep the
`QUALIFY ROW_NUMBER() ... = 1` anyway** — it is what kept every figure correct while that
was true, and nothing guarantees the next BOM lands clean. → `Q4`

**2. BOM must be `MAX(BOM)`, never `DATE_TRUNC('MONTH', CURRENT_DATE)`.** The current
month has no BOM row until the monthly ECL job runs, so on the 1st of a month the
calendar-month filter matches nothing and every ECL comes back NULL. Latest available
is still **2026-09-01** as of 21 Sep — there is no October BOM yet, which is why
extending the window to 20 Aug adds loans but *not* maturity (see trap 6).

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

**6. Seasoning confounds cross-month comparisons, and a later window end does NOT fix it.**
All ECL comes from one BOM snapshot, so July loans carry ~2 months of performance and
January loans ~8. Extending the window from 10 Aug to 20 Aug added 5,034 loans whose ECL
was struck when they were only **12–21 days old** — calendar time since disbursal is
irrelevant; what matters is the BOM date. **Control for seasoning by comparing cohorts
_within_ a month** — see the Fresh−Renewal spread in
[§6.2](#62-it-is-not-a-seasoning-artifact).

**7. Do not extend past 20 Aug.** Loans disbursed 21–31 Aug 2026 are in the snapshot with
**ECL of exactly 0.0%** (6,117 loans). Including them silently dilutes every rate.

Two smaller ones:

- `LOAN_DISBURSED_DATE` may carry a time component. Use a half-open interval
  (`>= '2026-07-01' AND < '2026-08-21'`), not `BETWEEN ... AND '2026-08-20'`, which
  silently drops most of 20 Aug.
- `is_dormant_flag` here is the **dashboard** definition (BRE input flag with a whitelist
  fallback), *not* the live routing dormancy (flag AND isFresh). They disagree for some
  users — see `WARN_dormant_flag_definition` in the ds_rca_repo knowledge base.

---

## 6. Findings so far

### 6.1 Cohort-level — Renewal is the cohort that deteriorated

Window totals (`Q1`). ECL coverage 100%; no unmapped loans.

| Cohort | Loans | Disbursed ₹Cr | Avg ticket ₹ | ECL ₹Cr | ECL % | vs Jan–Jun 2026 |
|---|---|---|---|---|---|---|
| Fresh | 10,041 | 114.18 | 113,709 | 5.75 | 5.04 | above 4 of 6 months |
| **Renewal** | 6,704 | 134.22 | 200,205 | 5.47 | **4.08** | **above all 6 months** |
| Dormant | 4,630 | 62.87 | 135,799 | 2.68 | 4.26 | above 5 of 6 months |
| AA | 1,171 | 18.02 | 153,911 | 0.80 | 4.45 | above 2 of 6 months |
| **All** | **22,546** | **329.29** | **146,053** | **14.70** | **4.47** | |

**The cohort with the highest loss rate is not the cohort that got worse.** Fresh carries
the highest rate (5.04%) and has now passed four of its six prior months — it was only past
two when the window ended on 10 Aug. Renewal at 4.08% is above *every* month of 2026; its
previous worst was 3.88% (January) and June was 3.05%.

Monthly ECL % by cohort (`Q2`), Aug = 1–10 only:

| Month | Fresh | Renewal | Dormant | AA |
|---|---|---|---|---|
| Jan | 4.74 | 3.88 | 5.25 | 4.98 |
| Feb | 4.91 | 3.80 | 3.87 | 4.64 |
| Mar | 5.32 | 3.62 | 3.95 | 5.17 |
| Apr | 5.20 | 3.64 | 4.14 | 4.62 |
| May | 5.02 | 3.81 | 4.16 | 4.05 |
| Jun | 4.40 | 3.05 | 3.56 | 3.53 |
| **Jul** | 4.84 | **4.15** | 4.24 | 4.59 |
| **Aug\*** | 5.31 | 3.95 | 4.30 | 4.17 |

Volume moved at the same time: the window ran 427 disbursals/day against June's 333
(+28%). Monthly loan counts went Fresh 4,290→6,024, Renewal 3,138→4,174, Dormant
1,919→2,695 into July (all roughly +37%).

### 6.2 It is not a seasoning artifact

The obvious objection to §6.1 is trap 6 — younger loans, less performance. The
**Fresh − Renewal ECL spread** controls for it: both cohorts sit in the same month with
the same seasoning, so anything that moves the gap between them is real.

| Jan | Feb | Mar | Apr | May | Jun | **Jul** | Aug\* |
|---|---|---|---|---|---|---|---|
| 0.86 | 1.11 | 1.70 | 1.56 | 1.21 | 1.35 | **0.69** | 1.36 |

Fresh normally runs 0.86–1.70 pp riskier than Renewal. In July that collapses to
**0.69 pp — the narrowest of the year** — then reopens to 1.36 pp across 1–20 August. Seasoning
moves both cohorts together and cannot close the gap between them. So July's compression
is Renewal deteriorating, and it looks like a **July-specific event** rather than a new
run rate.

### 6.3 Renewal by experiment type — one experiment dominates

`Q5`, 34 experiment types in Renewal. Ranked by **excess ECL** = rupees of loss above
what the experiment would carry at Renewal's own 4.08% rate (raw ECL ₹ just ranks by size).

| Experiment type | Loans | ECL ₹Cr | ECL % | Excess ₹Cr |
|---|---|---|---|---|
| **POLICY RULES OVERRULE RISK BUCKET B POLICY** | 610 | 0.937 | **7.39** | **+0.420** |
| 5 Lakh ATS Experiment | 50 | 0.156 | 6.78 | +0.062 |
| POLICY RULES OVERRULE RISK BUCKET C POLICY | 50 | 0.087 | 9.07 | +0.048 |
| Tenure Experiment: Risk Bucket B | 62 | 0.089 | 8.01 | +0.044 |
| … 28 more … | | | | |
| POLICY RULES OVERRULE POLICY | 869 | 0.582 | 3.32 | −0.132 |
| NORMAL LOAN | 2,179 | 1.115 | 3.07 | −0.365 |

`POLICY RULES OVERRULE RISK BUCKET B POLICY` holds **9.1% of Renewal's loans but 17.1%
of its ECL** — ₹0.420 Cr excess, 6.8× the next contributor. The plain `NORMAL LOAN` book,
a third of the cohort, runs at 3.07%. **The BAU renewal book is not the problem.**

The pattern generalises — every experiment overruling into **risk bucket B or C** runs
hot, and the bucket-A equivalent does not:

| Grouping | Loans | % of cohort loans | ECL ₹Cr | % of cohort ECL | ECL % |
|---|---|---|---|---|---|
| Risk bucket **B/C** overrule family (6 experiments) | 860 | 12.8 | 1.247 | **22.8** | **7.49** |
| NPS POLICY OVERRULE RISK BUCKET **A** | 276 | 4.1 | 0.161 | 2.9 | 4.21 |
| Renewal, all types | 6,704 | 100.0 | 5.469 | 100.0 | 4.08 |

The six: `POLICY RULES OVERRULE RISK BUCKET B POLICY`, `POLICY RULES OVERRULE RISK BUCKET
C POLICY`, `Tenure Experiment: Risk Bucket B`, `Tenure Experiment: Risk Bucket C`,
`NPS Experiment: Risk Bucket B`, `NPS POLICY OVERRULE RISK BUCKET B`. An eighth of
Renewal's loans, nearly a quarter of its loss. **Whatever is wrong is specific to
overruling into B and C, not to overruling as such.**

### 6.4 Inside the 500 — not a few bad loans; it's selection

`Q6` → `data/renewal_overrule_bucket_b_500_loans.csv` (now **610** rows × 28 cols; filename kept). **Not in git**
— see [§7](#7-repo-contents); regenerate it with the command there.

**Concentration — the loss is broad-based, and the control proves it.**

⚠️ **Methodological note.** The first version of this compared the 500 against a
*perfectly-even* loss distribution. That is the wrong benchmark — every credit book is
skewed (ECL scales with both loan size and risk), so no real portfolio sits near it, and
"16% of loans hold half the loss" means nothing on its own. The right benchmark is a
**healthy bucket in the same cohort and window**. Corrected 2026-09-12.

| Renewal bucket | Loans | ECL % | Worst 2% hold | Worst 10% hold | Half the loss in | Gini |
|---|---|---|---|---|---|---|
| NORMAL LOAN | 2,179 | 3.07 | 22.9% | 48.0% | 11% of loans | 0.647 |
| OVERRULE POLICY | 869 | 3.32 | 17.3% | 44.0% | 13% of loans | 0.590 |
| **OVERRULE-B experiment** | 610 | **7.39** | 11.1% | 36.8% | 16% of loans | **0.530** |
| *if every loan lost the same* | — | — | 2.0% | 10.0% | 50% of loans | 0.000 |

**Concentration runs opposite to loss rate.** The two healthy buckets sit at ~3.2% ECL
with *high* concentration — a small bad tail on a clean book, which is what a working
credit policy looks like. The overrule bucket has more than double the loss rate and the
**lowest** concentration of the three. There is no tail to remove; the book is worse all
the way through.

Loan-level ECL %: median **4.82** (already above Renewal's 4.08), p75 8.37. The *median* loan being above the cohort average is the clinching
number — in a few-blow-ups book the median looks fine and only the tail is ugly.

**They are already failing at MOB 1–2.** All 500 loans are 1–2 months on book at the
snapshot:

| Renewal bucket | Loans | ECL % | Ever DPD>0 | Ever 4+ DPD | Currently DPD | Avg prior-loan max DPD |
|---|---|---|---|---|---|---|
| **OVERRULE-B experiment** | 610 | **7.39** | **82.6%** | **20.7%** | **34.6%** | **3.99** |
| NORMAL LOAN | 2,179 | 3.07 | 52.3% | 5.3% | 11.5% | 1.88 |
| OVERRULE POLICY | 869 | 3.32 | 62.0% | 10.2% | 17.8% | 2.25 |
| All other Renewal | 3,046 | 4.19 | 59.8% | 7.5% | 15.5% | 2.21 |

**And they were selected that way.** Split by the previous loan's max-ever DPD
(control = the 4,810 Renewal loans not in this experiment):

| Prior loan max DPD | Overrule B loans | share | ECL % | Control loans | share | ECL % |
|---|---|---|---|---|---|---|
| 0 (clean) | 1 | 0.2% | 4.26 | 755 | 12.4% | 2.53 |
| 1–3 | 285 | 46.7% | **6.22** | 4,298 | 70.5% | 3.37 |
| 4–10 | 324 | **53.1%** | **8.35** | 1,011 | 16.6% | 5.99 |
| 11–30 | 0 | — | — | 29 | 0.5% | 8.32 |
| **All** | 610 | 100% | **7.39** | 6,094 | 100% | **3.73** |

Two things are wrong and they compound:

- **Mix** — 53% of the experiment comes from the 4–10 prior-DPD band vs 17% for the control,
  and just **1 of 610 loans has a clean prior loan** (vs 12.4%).
- **Performance within band** — even holding prior DPD fixed, these run 1.4–1.8× worse
  (6.22 vs 3.37 at 1–3; 8.35 vs 5.99 at 4–10).

So this **cannot** be written off as "we knowingly took 4–10 DPD borrowers and priced for
it". Something beyond prior DPD is being given up when this policy is overruled. The
11–30 band is correctly blocked — the leak is entirely in **4–10**.

### 6.5 Lender split inside the 500 — it's the policy, not a lender

`Q8`. Volume is concentrated: **VIVRITI 231 loans (37.9%)** and **Western Capital 206
(33.8%)** are 71.6% of the experiment. Loss is not — their loss share is 73.6%, i.e.
roughly proportional to volume.

Each lender is measured **against itself**: the same lender's Renewal loans, same window,
that went through any *other* experiment. That separates "risky lender" from "this policy
is bad at this lender".

| Lender | Loans | % of 500 | ECL % | Control loans | Control ECL % | Lift pp |
|---|---|---|---|---|---|---|
| VIVRITI | 231 | 37.9 | 7.29 | 1,543 | 3.02 | **+4.27** |
| Western Capital | 206 | 33.8 | 7.81 | 772 | 5.30 | +2.51 |
| SMICC | 55 | 9.0 | 6.31 | 965 | 2.91 | +3.39 |
| CAPRION | 29 | 4.8 | 8.05 | 772 | 5.62 | +2.43 |
| JUPITER | 32 | 5.2 | 7.06 | 622 | 3.41 | **+3.65** |
| SLICE | 28 | 4.6 | 6.09 | 1,089 | 2.90 | +3.19 |
| CASHTREE | 28 | 4.6 | 8.80 | 189 | 5.79 | +3.01 |
| NIYOGIN_APOLLO | 1 | 0.2 | 0.34 | 11 | 3.61 | −3.27 *(1 loan, ignore)* |
| **All** | **610** | **100** | **7.39** | **6,094** | **3.73** | **+3.66** |

**Every lender is worse inside the experiment**, by +2.43 to +4.27 pp. Lenders do carry
different baseline risk (SLICE 2.90% vs CASHTREE 5.79% on their other Renewal loans), and
the experiment adds loss on top of *all* of them.

Measured as excess against the bucket's own 7.35%, the largest single-lender contribution
is **₹0.017 Cr** — noise. **No lender is dragging this bucket**, and routing away from one
would not fix it: the policy produces the same bad book wherever it is sent. This is
consistent with §6.4 — broad-based, not concentrated.

### 6.6 The OVERRULE-B experiment did NOT cause the July move — lender turnover did

`Q9`, `Q10`. **This overturns the direction §6.3–6.5 was pointing.** Those sections show the
bucket is lossy; they never showed it *changed* in July, which is what would make it the
cause. Tracked monthly back to Apr 2025 (ECL coverage verified 100% every month, so no
survivorship bias), it doesn't.

**Decomposition of Renewal's +1.11 pp June→July move:**

Two exact cuts of the same +1.1100 pp. Both sum with no residual and no assumption.

**Cut A — by lender** (`Q11`, shift-share):

| Component | pp | Share |
|---|---|---|
| Same lenders got worse — *rate* | **+0.5280** | 47.9% |
| Lenders entering / leaving | **+0.5039** | 45.8% |
| Reshuffle among established lenders — *mix* | **+0.0693** | 6.3% |
| **Total** | **+1.1012** | 100% |

```text
rate effect = SUM over continuing lenders of  w_jun x (r_jul - r_jun)
mix effect  = SUM over continuing lenders of  (w_jul - w_jun) x r_jul
entry/exit  = total - rate - mix
  w = lender's share of DISBURSED AMOUNT among continuing lenders
  r = lender's ECL% that month
```

**Who counts as "continuing":** present in both months **and** ≥1% of June's Renewal
disbursal. The 1% cut is not arbitrary — June's lenders fall either side of it cleanly
(LENDBOX 1.67%, then CAPRION 0.57%, then nothing). CAPRION wrote 18 loans / ₹0.34 Cr in
June and 523 in July, so it is classed as an **entrant**, not a continuing relationship.

**The cut barely moves the headline.** Class CAPRION as continuing instead and rate is
+0.5293 vs +0.5280 — "the same lenders got worse" holds either way. What moves is where
CAPRION's ₹9.79 Cr of July volume books:

| | rate | mix | entry/exit |
|---|---|---|---|
| CAPRION as **entrant** (published) | +0.5280 | +0.0693 | **+0.5039** |
| CAPRION as continuing | +0.5293 | +0.4100 | +0.1622 |

Same total, same conclusion about the established lenders.

> **This supersedes the first-pass counterfactual method** ("what if new lenders had performed
> at the continuing-lender rate"), which needed an unverifiable assumption. The two land in
> nearly the same place — old "new lenders" 0.52 vs new entry/exit 0.5041; old "drift" 0.52 vs
> new rate 0.5365 — but the shift-share is exact, so use it.

**Worked arithmetic — rate effect** (`w` = share of disbursal among the six continuing
lenders, `r` = that lender's ECL% that month):

| Lender | w_jun | r_jun | r_jul | change | contribution |
|---|---|---|---|---|---|
| VIVRITI | 0.36751 | 3.101 | 3.703 | +0.602 | **+0.2212** |
| SLICE | 0.25653 | 2.593 | 3.192 | +0.599 | **+0.1537** |
| SMICC | 0.20881 | 2.978 | 3.108 | +0.130 | +0.0271 |
| JUPITER | 0.11434 | 3.306 | 3.631 | +0.325 | +0.0372 |
| CASHTREE | 0.03567 | 3.763 | 6.413 | +2.650 | +0.0945 |
| LENDBOX | 0.01713 | 2.760 | 2.423 | −0.336 | −0.0058 |
| **Rate effect** | | | | | **+0.5280** |

Five of six got worse. VIVRITI and SLICE supply two-thirds of it, both moving ~+0.60 pp on
large books. CASHTREE moved furthest (+2.65 pp) but is too small to contribute much.

**Worked arithmetic — mix effect:**

| Lender | w_jun | w_jul | shift | r_jul | contribution |
|---|---|---|---|---|---|
| JUPITER | 0.11435 | 0.15442 | +0.04007 | 3.631 | +0.1455 |
| CASHTREE | 0.03566 | 0.04812 | +0.01246 | 6.413 | +0.0799 |
| VIVRITI | 0.36752 | 0.37655 | +0.00903 | 3.703 | +0.0335 |
| LENDBOX | 0.01713 | 0.00994 | −0.00719 | 2.423 | −0.0174 |
| SMICC | 0.20881 | 0.19171 | −0.01710 | 3.108 | −0.0532 |
| SLICE | 0.25653 | 0.21925 | −0.03727 | 3.192 | −0.1190 |
| **Mix effect** | | | | | **+0.0693** |

Nearly self-cancelling — JUPITER gaining share offsets SLICE losing it. Reshuffling volume
among established lenders is not part of the story.

**Worked arithmetic — entry/exit is a dilution, not a leftover:**

```text
The six continuing lenders, as a block:
  their own blended rate     June 2.9862%  ->  July 3.5835%   = +0.5973 pp
  and  +0.5973 = rate +0.5280 + mix +0.0693      <- the two tables above

  their share of the book    June  97.20%  ->  July  78.48%
  entrants took 21.52% of July at 6.232%  (CAPRION, Western Capital, NIYOGIN_APOLLO)
  NIYOGIN held   2.80% of June at 5.261%  and left

  June total = 0.9720 x 2.9862 + 0.0280 x 5.2612 = 3.0521%
  July total = 0.7848 x 3.5835 + 0.2152 x 6.2320 = 4.1533%
  TOTAL MOVE                                     = +1.1012 pp

ENTRY/EXIT = total move - the block's own change = 1.1012 - 0.5973 = +0.5039 pp
```

The +0.5039 is **dilution**: the continuing block's rate rose only 0.60 pp, but it shrank
from 97.2% to 78.5% of the book, and what replaced it ran at **6.23% against the block's
3.58%**. Nearly a fifth of July's Renewal lending came from lenders barely present in June,
at almost double the rate of those who were.

*(4-dp totals are computed on unrounded rupees; reproducing them from the 3-dp rates above
drifts ~0.002 pp.)*

**Cut B — by experiment:**

| Component | pp | Share |
|---|---|---|
| OVERRULE-B experiment growing its excess | **+0.0658** | 6.0% |
| Everything else | +1.0354 | 94.0% |

**Deriving the +0.0658 from rupees** (this is where `0.09491 × 3.508 − 0.08201 × 3.257` comes from):

| | Disbursed ₹ | ECL ₹ | ECL % |
|---|---|---|---|
| June — OVERRULE-B | 48,846,424 | 2,951,379 | 6.042 |
| June — rest of Renewal | 546,802,537 | 15,227,911 | 2.785 |
| **June — all Renewal** | **595,648,961** | **18,179,290** | **3.0521** |
| July — OVERRULE-B | 79,687,795 | 5,839,617 | 7.328 |
| July — rest of Renewal | 759,938,664 | 29,032,474 | 3.820 |
| **July — all Renewal** | **839,626,459** | **34,872,091** | **4.1533** |

```text
share = OVERRULE-B disbursed / all Renewal disbursed
  June:  48,846,424 / 595,648,961 = 0.08201
  July:  79,687,795 / 839,626,459 = 0.09491

lift  = OVERRULE-B ECL% - rest-of-Renewal ECL%
  June:  6.042 - 2.785 = 3.257
  July:  7.328 - 3.820 = 3.508

contribution = share x lift
  June:  0.08201 x 3.257 = 0.2671 pp
  July:  0.09491 x 3.508 = 0.3329 pp
  CHANGE = +0.0658 pp  ->  6.0% of +1.1012
```

Identity check: `0.08201 x 6.042 + 0.91799 x 2.785 = 3.0521%` and
`0.09491 x 7.328 + 0.90509 x 3.820 = 4.1533%` — both match the measured monthly rates exactly.

**The OVERRULE-B experiment is a slow burn, not a July event.** Its share of Renewal fell through 2026 to a
7.1% low in June and rose to 8.7% in July — but it ran 13–16% through most of 2025, so July
is unremarkable. What *has* moved is its lift over the rest of the cohort, widening every
month of 2026:

| Month | OVERRULE-B loans | Share of Renewal | OVERRULE-B ECL % | Rest ECL % | Lift pp | Contribution pp |
|---|---|---|---|---|---|---|
| Apr 2026 | 273 | 9.3% | 5.48 | 3.43 | +2.05 | 0.201 |
| May 2026 | 231 | 7.7% | 6.32 | 3.58 | +2.74 | 0.223 |
| Jun 2026 | 224 | 7.1% | 6.04 | 2.78 | +3.26 | 0.267 |
| Jul 2026 | 365 | 8.7% | 7.33 | 3.82 | **+3.51** | 0.333 |
| Aug 2026* | 245 | 9.7% | 7.50 | 3.58 | **+3.92** | 0.367 |

*(Apr 2026 onward, as requested. `Q9` returns the full series back to Apr 2025, where the
experiment ran 13–16% of Renewal through most of 2025 — which is why July's 8.7% is not a
notable share by historical standards. Apr 2026 values re-measured 15 Sep; they moved from
3.39/3.60 on 12 Sep — see trap 0.)*

`lift_pp` is the seasoning-immune column — both sides share a month, vintage and BOM
snapshot, so only a real change in relative quality moves it. Compare `ecl_pct` down a
column only loosely (trap 6). Full series in `Q9`.

**What actually changed: the lender panel turned over.** Non-bucket Renewal, June vs July:

| Lender | Jun loans | Jun ECL % | Jul loans | Jul ECL % | % of Jul book |
|---|---|---|---|---|---|
| **CAPRION** | 18 | 5.59 | **523** | **6.34** | 12.9% |
| **Western Capital** | **0** | — | **371** | **6.12** | 10.8% |
| VIVRITI | 1,076 | 3.10 | 1,246 | 3.70 | 32.7% |
| SLICE | 715 | 2.59 | 662 | 3.19 | 19.0% |
| SMICC | 657 | 2.98 | 667 | 3.11 | 16.6% |
| JUPITER | 355 | 3.31 | 459 | 3.63 | 13.4% |
| CASHTREE | 125 | 3.76 | 160 | 6.41 | 4.2% |
| LENDBOX | 117 | 2.76 | 83 | 2.42 | 0.9% |
| **NIYOGIN** *(exited)* | 75 | 5.26 | **0** | — | 0.0% |

- **CAPRION**: 18 → 523 Renewal loans, a 29× jump, at 6.34%.
- **Western Capital**: **zero** Renewal loans in June, 371 in July at 6.12% plus 75 inside the
  overrule bucket. A brand-new counterparty, not an expansion — which also means its Q8
  "control" baseline (§6.5) is its own first six weeks, so read that lift cautiously.
- **NIYOGIN**: 12 months in the experiment, stopped entirely after June. `NIYOGIN_APOLLO`
  appears in Aug with 1 loan — likely a re-onboarding, **worth confirming**.

Newcomers wrote **21.5% of July's Renewal disbursal at 6.23% ECL, vs 3.58% for lenders
already there**.

**Still unexplained: the +0.5280 rate effect — the largest single component.** Every
continuing lender got worse in the same month: VIVRITI 3.10→3.70, SLICE 2.59→3.19, SMICC
2.94→3.11, JUPITER 3.31→3.63, CASHTREE 3.76→6.41. A simultaneous rise across unrelated
counterparties is neither a lender problem nor an experiment problem — it points upstream of
both (scoring, policy, or the applicant population itself). **Start here.**

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
| `Q10_overrule_bucket_b_lender_by_month.sql` | Lender entry/exit inside the experiment, with NEW/EXITED/CONTINUING status | §6.6 |
| `Q11_july_move_decomposition.sql` | Per-lender inputs for the exact shift-share of the June→July move | §6.6 Cut A. **Supersedes the counterfactual method** |

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
   explain the 1.4–1.8× gap. What else does the overruled policy screen on?
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

- **Window extended 10 Aug → 20 Aug on 2026-09-21**, adding 5,034 loans (+28.7%). All
  figures in this file are the extended window unless stated.
- **August is 20 days** (8,876 loans), not a month. **Aug 21–31 is excluded deliberately** —
  those 6,117 loans carry ECL of exactly 0.0% in the current snapshot (trap 7).
- **Extending the window did not add maturity.** ECL is struck at the BOM, still
  2026-09-01, so the added loans were 12–21 days old when measured — not ~30 (trap 6).
- All ECL is one snapshot, **BOM 2026-09-01**. Re-running later moves every number (trap 0).
- Cohort ordering is a modelling choice (§3).

### What the extension changed

| | to 10 Aug | to 20 Aug |
|---|---|---|
| Loans | 17,512 | **22,546** |
| Disbursed | ₹255.74 Cr | **₹329.29 Cr** |
| Blended ECL | 4.44% | **4.47%** |
| Fresh | 4.89% — above 2 of 6 | **5.04% — above 4 of 6** |
| Renewal | 4.10% — above all 6 | **4.08% — above all 6** |
| Dormant | 4.32% — above 5 of 6 | **4.26% — above 5 of 6** |
| OVERRULE-B experiment | 500 loans, 7.35% | **610 loans, 7.39%** |

Every conclusion survives. The one material move is **Fresh**, which went from "highest but
normal" to "highest and now above four of its six prior months" — worth watching.
