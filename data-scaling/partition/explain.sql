-- The plans of the feed read for user 1, first page and a page 15 days back, on the timeline search_path picks:
-- which partitions the plan holds, how many startup pruning removes (now() is only known when the query runs) and
-- how many the ordered scan never reaches.

-- A new session plans its first query on a partitioned table with every partition's metadata still to load; the
-- service's pooled connections have it already, so one query loads it before the plans are timed.
SELECT count(*) AS warm FROM timeline WHERE user_id = md5('1')::uuid AND published_at > now() - interval '30 days' \gset

EXPLAIN (ANALYZE, BUFFERS)
SELECT v.video_id, v.author_id, v.title, v.duration_ms, v.playlist_key, v.thumbnail_key, v.published_at, v.premium
FROM timeline t
JOIN videos v ON v.video_id = t.video_id
WHERE t.user_id = md5('1')::uuid
  AND t.published_at > now() - interval '30 days'
  AND (t.published_at, t.video_id) < (COALESCE(NULL::timestamptz, 'infinity'),
    '00000000-0000-0000-0000-000000000000'::uuid)
ORDER BY t.published_at DESC, t.video_id DESC
LIMIT 11;
\echo ----
EXPLAIN (ANALYZE, BUFFERS)
SELECT v.video_id, v.author_id, v.title, v.duration_ms, v.playlist_key, v.thumbnail_key, v.published_at, v.premium
FROM timeline t
JOIN videos v ON v.video_id = t.video_id
WHERE t.user_id = md5('1')::uuid
  AND t.published_at > now() - interval '30 days'
  AND (t.published_at, t.video_id) < (COALESCE(now() - interval '15 days', 'infinity'),
    'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid)
ORDER BY t.published_at DESC, t.video_id DESC
LIMIT 11;
