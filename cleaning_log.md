# Cleaning Log and Data-Quality Summary

**Experiment:** EXP-PODVID-014 (Video-First Discovery Feed) &nbsp;|&nbsp; **Author:** Amit Verma

Every check below is reproducible from [`analysis.sql`](analysis.sql) (sections 1 and 3) and the first sections of [`analysis.ipynb`](analysis.ipynb).

## 1. Source tables

| Table | Rows | Grain | Key columns |
|---|---|---|---|
| `users_experiment_map` | 2,000 | one row per enrolled user | `User_ID`, `Variant`, `Region`, `Premium_Status`, `Account_Age_Days` |
| `daily_user_activity` | 19,741 | one row per user per day | `Date`, `User_ID`, `Podcast_Minutes_Listened`, `Music_Minutes_Listened`, `Discovery_Feed_Clicks`, `App_Crashes` |

Window: 3 March 2025 to 16 March 2025 (14 days). `User_ID` is unique in the user map (no duplicate enrolments), and `Variant` and `Premium_Status` labels are clean.

## 2. Row reconciliation (activity table)

Steps are applied in this order so nothing is counted twice. The row count reconciles at every step.

| Step | Rows removed | Rows remaining |
|---|---:|---:|
| Raw activity rows | n/a | **19,741** |
| 1. Drop exact duplicate rows | 78 | 19,663 |
| 2. Drop orphan rows (User_ID not in user map) | 20 | 19,643 |
| 3. Drop impossible podcast values (> 1,440 min/day) | 12 | **19,631** |
| **Total removed** | **110 (0.56%)** | |

Final analysis table: **2,000 users** (1,015 Control, 985 Treatment), one row per user.

## 3. Issue register

| # | Issue | Size | Treatment | Why |
|---|---|---:|---|---|
| 1 | Exact duplicate user-days | 78 rows (156 rows involved) | Keep one copy (`ROW_NUMBER` by `User_ID` + `Date`) | Every duplicate was an exact copy, so no information is lost and totals are not double-counted |
| 2 | Orphan IDs not in the experiment map | 20 rows, 20 IDs | Dropped (a LEFT JOIN from the user table removes them automatically) | They cannot be assigned to a variant |
| 3 | Podcast minutes above 24 hours | 13 raw rows, 12 after de-duplication (range 1,855 to 2,985) | Dropped | A day has only 1,440 minutes, so these are logging errors |
| 4 | Null podcast minutes | 158 raw, 157 after cleaning | Kept as null: excluded from minute sums, row still counts as an active day | Null means "not recorded", not zero listening, and the user was still active that day |
| 5 | Non-standard Region labels | 47 users (e.g. `' north america '`, `EUROPE`, `' latam '`) | `UPPER(TRIM())` then mapped to 5 canonical names | Prevents one region splitting into several groups |
| 6 | Null `Account_Age_Days` | 30 users | Left as null | Only used for a balance check, where nulls are excluded |
| 7 | Users with no activity | 0 | n/a (handled by design) | The LEFT JOIN would keep them with zeros if they existed |

Checks that found no problem: negative values (none in any numeric column), music minutes (max 831.6, plausible), feed clicks (max 12), app crashes (max 2), `Variant` and `Premium_Status` labels.

## 4. Analysis-population decisions

- **Unit of analysis: the user.** Daily rows are repeated measures of one person. Testing them as independent rows would shrink p-values artificially (pseudoreplication), so each user is collapsed to one row of 14-day averages.
- **Intent-to-treat.** Every enrolled user is kept. Inactive days count as zero, and the denominator is always 14 days, not "days active".
- **No outlier trimming beyond impossible values.** Heavy listeners are real behavior. Robustness is checked instead with a rank test and a bootstrap CI.

## 5. Known limitations of the data

- **No cancellation events.** The Premium cancellation guardrail from the PRD cannot be evaluated with these two tables.
- **Region imbalance.** Arms differ slightly on Region (chi-square p = 0.026). A region-adjusted estimate is reported alongside the main result and is essentially unchanged.
