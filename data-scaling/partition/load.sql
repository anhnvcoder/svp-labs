-- Synthetic data of the feed shape from the psql variables users, follows (authors each user follows) and
-- videos_per_day: one user in ten posts, follows spread evenly, so every author has users * follows / authors
-- followers. User n's id is md5(n)::uuid, the form the pgbench scripts use. Prints one line starting with load|.
SELECT greatest(:users / 10, 1) AS authors, now() AS gen,
    date_trunc('day', now() - interval '30 days') AS mark_day,
    now() - interval '30 days' + interval '2 hours' AS gap_end
\gset

-- One partition a day from the day before the one holding the 30-day mark to tomorrow, so that the write load
-- keeps a partition to insert into if the run crosses midnight UTC.
SELECT format('CREATE TABLE part.%I PARTITION OF part.timeline FOR VALUES FROM (%L) TO (%L)',
    'timeline_p' || to_char(day, 'YYYYMMDD'), day, day + interval '1 day')
FROM generate_series(:'mark_day'::timestamptz - interval '1 day',
    date_trunc('day', :'gen'::timestamptz) + interval '1 day', interval '1 day') AS day
\gexec

INSERT INTO follows (followee_id, follower_id, created_at)
SELECT md5(((u + j * greatest(:authors / :follows, 1)) % :authors + 1)::text)::uuid, md5(u::text)::uuid,
    :'gen'::timestamptz - interval '60 days'
FROM generate_series(1, :users) AS u, generate_series(0, :follows - 1) AS j
WHERE (u + j * greatest(:authors / :follows, 1)) % :authors + 1 <> u
ON CONFLICT DO NOTHING;

-- A full day of videos before the day of the 30-day mark, then none until two hours past the mark: DELETE (rows
-- older than the mark when it runs) and DETACH (whole days older than the mark) then remove the same rows, as long
-- as the cleanups start within those two hours.
INSERT INTO videos (video_id, author_id, title, duration_ms, playlist_key, thumbnail_key, published_at)
SELECT id, author, 'video ' || id, 30000, 'videos/' || id || '/hls/index.m3u8', 'videos/' || id || '/thumb.jpg', at
FROM (
    SELECT gen_random_uuid() AS id, md5((1 + floor(random() * :authors))::int::text)::uuid AS author, at
    FROM (
        SELECT :'mark_day'::timestamptz - interval '1 day' + random() * interval '1 day' AS at
        FROM generate_series(1, :videos_per_day)
        UNION ALL
        SELECT :'gap_end'::timestamptz + random() * (:'gen'::timestamptz - :'gap_end'::timestamptz)
        FROM generate_series(1, round(:videos_per_day
            * extract(epoch FROM :'gen'::timestamptz - :'gap_end'::timestamptz) / 86400)::int)
    ) AS t
) AS v;

-- In publish order, as fan-out writes it: the oldest rows sit at the start of the heap.
INSERT INTO plain.timeline (user_id, published_at, video_id, created_at)
SELECT f.follower_id, v.published_at, v.video_id, v.published_at
FROM videos AS v JOIN follows AS f ON f.followee_id = v.author_id
ORDER BY v.published_at;

INSERT INTO part.timeline SELECT * FROM plain.timeline ORDER BY published_at;

VACUUM (ANALYZE) follows, videos, plain.timeline, part.timeline;
CHECKPOINT;

SELECT 'load', :users, :authors, :follows, :videos_per_day,
    (SELECT count(*) FROM follows), (SELECT count(*) FROM videos), (SELECT count(*) FROM plain.timeline),
    (SELECT count(*) FROM plain.timeline WHERE published_at < :'mark_day'::timestamptz),
    pg_total_relation_size('plain.timeline'),
    (SELECT sum(pg_total_relation_size(relid)) FROM pg_partition_tree('part.timeline')),
    (SELECT count(*) FROM pg_partition_tree('part.timeline') WHERE isleaf),
    pg_database_size(current_database()), :'gap_end';
