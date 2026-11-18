-- pgbench: one video.ready as the feed-service projector stores it, in one transaction: the author's lock, the
-- video, then FanOutVideo into the timeline of every follower. -D authors=N; search_path picks the timeline.
\set a random(1, :authors)
BEGIN;
SELECT pg_advisory_xact_lock(hashtextextended('feed-author:' || md5(:a::text)::uuid::text, 0));
INSERT INTO videos (video_id, author_id, title, duration_ms, playlist_key, thumbnail_key, published_at, premium)
VALUES (gen_random_uuid(), md5(:a::text)::uuid, 'video', 30000, 'videos/new/hls/index.m3u8', 'videos/new/thumb.jpg',
    now(), false)
ON CONFLICT (video_id) DO NOTHING
RETURNING video_id AS vid
\gset
INSERT INTO timeline (user_id, published_at, video_id)
SELECT f.follower_id, v.published_at, v.video_id
FROM follows f JOIN videos v ON v.video_id = :vid AND v.author_id = md5(:a::text)::uuid
WHERE f.followee_id = md5(:a::text)::uuid
ON CONFLICT DO NOTHING;
END;
