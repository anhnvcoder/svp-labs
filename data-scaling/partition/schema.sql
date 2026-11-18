-- The feed-service read model twice: timeline as the service has it (schema plain) and partitioned by day on
-- published_at (schema part), beside the follows and videos it joins (public). The service's queries run unchanged
-- on either copy through search_path. Design notes: data-scaling/README.md
CREATE EXTENSION pg_stat_statements;
CREATE ROLE svp_app LOGIN;
CREATE SCHEMA plain;
CREATE SCHEMA part;

CREATE TABLE public.follows (
    followee_id uuid        NOT NULL,
    follower_id uuid        NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (followee_id, follower_id)
);

CREATE TABLE public.videos (
    video_id      uuid        PRIMARY KEY,
    author_id     uuid        NOT NULL,
    title         text        NOT NULL,
    duration_ms   bigint      NOT NULL,
    playlist_key  text        NOT NULL,
    thumbnail_key text        NOT NULL,
    published_at  timestamptz NOT NULL,
    created_at    timestamptz NOT NULL DEFAULT now(),
    premium       boolean     NOT NULL DEFAULT false
);
CREATE INDEX videos_author_published_idx ON public.videos (author_id, published_at DESC, video_id DESC);
CREATE INDEX videos_published_idx ON public.videos (published_at DESC, video_id DESC);

CREATE TABLE plain.timeline (
    user_id      uuid        NOT NULL,
    published_at timestamptz NOT NULL,
    video_id     uuid        NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (user_id, published_at, video_id)
);

-- No default partition: DETACH ... CONCURRENTLY refuses a table that has one, and a row outside every day fails
-- loudly instead of landing in a partition no cleanup drops. The days themselves come with the data (load.sql).
CREATE TABLE part.timeline (
    user_id      uuid        NOT NULL,
    published_at timestamptz NOT NULL,
    video_id     uuid        NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (user_id, published_at, video_id)
) PARTITION BY RANGE (published_at);

GRANT USAGE ON SCHEMA plain, part TO svp_app;
GRANT SELECT, INSERT ON public.follows, public.videos, plain.timeline, part.timeline TO svp_app;

-- The prune loop of feed-service: a transaction per batch, so each batch commits its row locks and WAL before the
-- next one starts, until a batch finds fewer rows than it may delete.
CREATE PROCEDURE plain.prune_timeline(
    batch int, INOUT deleted bigint DEFAULT 0, INOUT batches int DEFAULT 0, INOUT longest_ms bigint DEFAULT 0
)
LANGUAGE plpgsql AS $$
DECLARE
    n bigint;
    started timestamptz;
BEGIN
    LOOP
        started := clock_timestamp();
        DELETE FROM plain.timeline
        WHERE (user_id, published_at, video_id) IN (
            SELECT user_id, published_at, video_id FROM plain.timeline
            WHERE published_at < now() - interval '30 days'
            LIMIT batch
        );
        GET DIAGNOSTICS n = ROW_COUNT;
        COMMIT;
        deleted := deleted + n;
        batches := batches + 1;
        longest_ms := greatest(longest_ms, round(extract(epoch FROM clock_timestamp() - started) * 1000));
        EXIT WHEN n < batch;
    END LOOP;
END
$$;
