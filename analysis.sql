-- =====================================================================
--  Spotify Podcasts: Video-First Discovery Feed A/B Test (EXP-PODVID-014)
--  Author  : Amit Verma
--  Dialect : SQLite 3.25+ (needs window functions)
--  Tables  : users_experiment_map   (one row per enrolled user)
--            daily_user_activity    (one row per user per day)
--  Flow    : 1 Audit -> 2 SRM counts -> 3 Clean + build views
--            -> 4 Variant summary -> 5 Segments -> 6 Daily trend
--  Notes   : Statistical tests (SRM chi-square, Welch t-test, CIs) run in
--            Python, see analysis.ipynb. SQL does the audit, cleaning and
--            aggregation.
-- =====================================================================


-- =====================================================================
-- 1. DATA AUDIT  (each query is independent, expected result in comment)
-- =====================================================================

-- 1a. Orphan activity rows: User_ID is not in the experiment map.  -> 20
SELECT COUNT(*) AS orphan_rows
FROM daily_user_activity a
LEFT JOIN users_experiment_map u ON a.User_ID = u.User_ID
WHERE u.User_ID IS NULL;

-- 1b. Duplicate user-days (same User_ID + Date more than once).     -> 78
--     Every duplicate was an exact copy, so keeping one row is safe.
SELECT COUNT(*) AS duplicated_user_days
FROM (SELECT User_ID, Date
      FROM daily_user_activity
      GROUP BY User_ID, Date
      HAVING COUNT(*) > 1);

-- 1c. Impossible podcast minutes (more than 24h = 1,440 min a day). -> 13 raw (12 after de-dup)
SELECT COUNT(*) AS impossible_rows
FROM daily_user_activity
WHERE Podcast_Minutes_Listened > 1440;

-- 1d. Missing values                                               -> 158 and 30
SELECT SUM(Podcast_Minutes_Listened IS NULL) AS null_podcast_minutes
FROM daily_user_activity;

SELECT SUM(Account_Age_Days IS NULL) AS null_account_age
FROM users_experiment_map;

-- 1e. Inconsistent Region labels (casing and stray spaces)         -> 47 users
SELECT Region, COUNT(*) AS users
FROM users_experiment_map
GROUP BY Region
ORDER BY users DESC;

-- 1f. Enrolled users with no activity rows at all                  -> 0 (edge case does not occur)
SELECT COUNT(*) AS users_without_activity
FROM users_experiment_map u
LEFT JOIN daily_user_activity a ON u.User_ID = a.User_ID
WHERE a.User_ID IS NULL;


-- =====================================================================
-- 2. SAMPLE RATIO CHECK (counts only, chi-square is done in Python)
-- =====================================================================
SELECT Variant, COUNT(*) AS users             -- Control 1015, Treatment 985
FROM users_experiment_map
GROUP BY Variant;


-- =====================================================================
-- 3. CLEAN + BUILD USER-LEVEL TABLE
--    Design choices
--      * One row per USER: daily rows are repeated measures of the same
--        person, so testing them as independent rows would overstate
--        significance (pseudoreplication).
--      * LEFT JOIN from users: every enrolled user is kept (intent-to-treat)
--        and inactive days count as zero.
--      * Denominator is always 14, not "days active".
--      * Orphan IDs drop out automatically because the join starts at users.
-- =====================================================================
DROP VIEW IF EXISTS v_user_metrics;
DROP VIEW IF EXISTS v_clean_activity;
DROP VIEW IF EXISTS v_clean_users;

-- 3a. Standardise Region labels
CREATE VIEW v_clean_users AS
SELECT User_ID, Variant,
       CASE UPPER(TRIM(Region))
            WHEN 'NORTH AMERICA' THEN 'North America'
            WHEN 'EUROPE'        THEN 'Europe'
            WHEN 'LATAM'         THEN 'LATAM'
            WHEN 'APAC'          THEN 'APAC'
            WHEN 'MEA'           THEN 'MEA'
       END AS Region,
       Premium_Status, Account_Age_Days
FROM users_experiment_map;

-- 3b. De-duplicate user-days and drop impossible podcast values
--     (NULL minutes are kept: they add nothing to sums but still count as an active day)
CREATE VIEW v_clean_activity AS
WITH deduped AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY User_ID, Date ORDER BY Date) AS rn
    FROM daily_user_activity
)
SELECT User_ID, Date,
       Podcast_Minutes_Listened AS podcast_min,
       Music_Minutes_Listened   AS music_min,
       Discovery_Feed_Clicks    AS clicks,
       App_Crashes              AS crashes
FROM deduped
WHERE rn = 1
  AND (Podcast_Minutes_Listened IS NULL OR Podcast_Minutes_Listened <= 1440);

-- 3c. One row per user (2,000 rows)
CREATE VIEW v_user_metrics AS
SELECT u.User_ID, u.Variant, u.Region, u.Premium_Status, u.Account_Age_Days,
       COALESCE(SUM(a.podcast_min), 0) / 14.0 AS avg_daily_podcast_min,   -- PRIMARY
       COALESCE(SUM(a.music_min),   0) / 14.0 AS avg_daily_music_min,     -- guardrail
       COALESCE(SUM(a.clicks),      0) / 14.0 AS avg_daily_clicks,        -- mechanism
       COALESCE(SUM(a.crashes),     0) / 14.0 AS avg_daily_crashes,       -- guardrail
       COUNT(a.Date) / 14.0                   AS active_day_rate,         -- guardrail
       COALESCE(SUM(CASE WHEN a.podcast_min > 0 THEN 1 ELSE 0 END), 0) AS podcast_days
FROM v_clean_users u
LEFT JOIN v_clean_activity a ON u.User_ID = a.User_ID
GROUP BY u.User_ID, u.Variant, u.Region, u.Premium_Status, u.Account_Age_Days;

-- Sanity check: must be exactly 2,000 users
SELECT COUNT(*) AS users_in_analysis FROM v_user_metrics;


-- =====================================================================
-- 4. SUMMARY BY VARIANT
--    Expected: Control 10.35 podcast min, Treatment 11.42 (+10.4%)
-- =====================================================================
SELECT Variant,
       COUNT(*)                            AS users,
       ROUND(AVG(avg_daily_podcast_min),2) AS mean_podcast_min,
       ROUND(AVG(avg_daily_music_min),2)   AS mean_music_min,
       ROUND(AVG(avg_daily_clicks),3)      AS mean_clicks,
       ROUND(AVG(avg_daily_crashes),4)     AS mean_crashes,
       ROUND(AVG(active_day_rate),3)       AS mean_active_rate,
       ROUND(AVG(podcast_days),2)          AS mean_podcast_days
FROM v_user_metrics
GROUP BY Variant;


-- =====================================================================
-- 5. SEGMENT VIEW (exploratory only, tests are in the notebook)
-- =====================================================================
SELECT Premium_Status AS segment_value, 'Premium_Status' AS segment, Variant,
       COUNT(*) AS users, ROUND(AVG(avg_daily_podcast_min),2) AS mean_podcast_min
FROM v_user_metrics GROUP BY Premium_Status, Variant
UNION ALL
SELECT Region, 'Region', Variant,
       COUNT(*), ROUND(AVG(avg_daily_podcast_min),2)
FROM v_user_metrics GROUP BY Region, Variant
ORDER BY segment, segment_value, Variant;


-- =====================================================================
-- 6. DAILY TREND (novelty-effect check)
--    Average podcast minutes per ENROLLED user per day (not per active user)
-- =====================================================================
SELECT a.Date, u.Variant,
       ROUND(SUM(COALESCE(a.podcast_min,0)) * 1.0 / g.n, 2) AS avg_podcast_min_per_user
FROM v_clean_activity a
JOIN v_clean_users u ON a.User_ID = u.User_ID
JOIN (SELECT Variant, COUNT(*) AS n FROM users_experiment_map GROUP BY Variant) g
     ON g.Variant = u.Variant
GROUP BY a.Date, u.Variant
ORDER BY a.Date, u.Variant;
