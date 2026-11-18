-- pgbench: GetFollowingFeed of feed-service at its default page of 10 items (it asks one more to know a next page
-- exists). Three reads in four open the feed (no cursor); the fourth asks for the page before a cursor up to 30
-- days back. -D users=N; search_path picks the plain or the partitioned timeline.
\set uid random(1, :users)
\set deep random(1, 4)
\if :deep = 4
\set age random(3600, 2592000)
SELECT v.video_id, v.author_id, v.title, v.duration_ms, v.playlist_key, v.thumbnail_key, v.published_at, v.premium
FROM timeline t
JOIN videos v ON v.video_id = t.video_id
WHERE t.user_id = md5(:uid::text)::uuid
  AND t.published_at > now() - interval '30 days'
  AND (t.published_at, t.video_id) < (COALESCE(now() - make_interval(secs => :age), 'infinity'),
    'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid)
ORDER BY t.published_at DESC, t.video_id DESC
LIMIT 11;
\else
SELECT v.video_id, v.author_id, v.title, v.duration_ms, v.playlist_key, v.thumbnail_key, v.published_at, v.premium
FROM timeline t
JOIN videos v ON v.video_id = t.video_id
WHERE t.user_id = md5(:uid::text)::uuid
  AND t.published_at > now() - interval '30 days'
  AND (t.published_at, t.video_id) < (COALESCE(NULL::timestamptz, 'infinity'),
    '00000000-0000-0000-0000-000000000000'::uuid)
ORDER BY t.published_at DESC, t.video_id DESC
LIMIT 11;
\endif
