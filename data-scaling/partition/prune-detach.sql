-- The same cleanup on the partitioned timeline: every day wholly older than the 30-day mark is detached without
-- an ACCESS EXCLUSIVE lock on the parent (CONCURRENTLY, so one statement per transaction), then dropped. WAL is
-- read as in prune-delete.sql. Prints one line starting with detach|.
CREATE TEMP TABLE expired AS
SELECT c.relname
FROM pg_inherits AS i JOIN pg_class AS c ON c.oid = i.inhrelid
WHERE i.inhparent = 'part.timeline'::regclass
  -- The planner may test this on any row of pg_class before the join: the CASE keeps to_date off other names.
  AND CASE WHEN c.relname ~ '^timeline_p[0-9]{8}$' THEN (to_date(right(c.relname, 8), 'YYYYMMDD') + 1)::timestamptz
      END <= now() - interval '30 days';
SELECT count(*) AS partitions,
    (SELECT count(*) FROM part.timeline WHERE published_at < date_trunc('day', now() - interval '30 days')) AS removed,
    (SELECT sum(pg_total_relation_size(relid)) FROM pg_partition_tree('part.timeline')) AS size0
FROM expired \gset
SELECT pg_stat_statements_reset() IS NOT NULL AS reset \gset
SELECT clock_timestamp() AS t0, pg_current_wal_lsn() AS lsn0 \gset
SELECT format('ALTER TABLE part.timeline DETACH PARTITION part.%I CONCURRENTLY', relname) FROM expired \gexec
SELECT clock_timestamp() AS d1 \gset
SELECT format('DROP TABLE part.%I', relname) FROM expired \gexec
SELECT clock_timestamp() AS t1, pg_current_wal_lsn() AS lsn1 \gset
SELECT pg_stat_force_next_flush();
SELECT 'detach', :removed, :partitions,
    round(extract(epoch FROM :'d1'::timestamptz - :'t0'::timestamptz) * 1000),
    round(extract(epoch FROM :'t1'::timestamptz - :'t0'::timestamptz) * 1000),
    pg_wal_lsn_diff(:'lsn1', :'lsn0'),
    (SELECT sum(wal_bytes) FROM pg_stat_statements
        WHERE userid = (SELECT oid FROM pg_roles WHERE rolname = current_user)),
    (SELECT sum(n_dead_tup) FROM pg_stat_user_tables
        WHERE relid IN (SELECT relid FROM pg_partition_tree('part.timeline'))),
    :size0, (SELECT sum(pg_total_relation_size(relid)) FROM pg_partition_tree('part.timeline'));
