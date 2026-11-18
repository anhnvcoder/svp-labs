-- The 30-day cleanup of the plain timeline as feed-service runs it, batches of 5000 rows. WAL is read two ways: the
-- LSN moves with every session's WAL (the write load's too); pg_stat_statements counts this session's own, as the
-- loads log in as svp_app. Prints one line starting with delete|.
SELECT pg_stat_statements_reset() IS NOT NULL AS reset \gset
SELECT clock_timestamp() AS t0, pg_current_wal_lsn() AS lsn0, pg_total_relation_size('plain.timeline') AS size0 \gset
CALL plain.prune_timeline(5000) \gset
SELECT clock_timestamp() AS t1, pg_current_wal_lsn() AS lsn1 \gset
-- This session's counters reach the shared statistics when it goes idle; the next statement reads them there.
SELECT pg_stat_force_next_flush();
SELECT 'delete', :deleted, :batches, :longest_ms,
    round(extract(epoch FROM :'t1'::timestamptz - :'t0'::timestamptz) * 1000),
    pg_wal_lsn_diff(:'lsn1', :'lsn0'),
    (SELECT sum(wal_bytes) FROM pg_stat_statements
        WHERE userid = (SELECT oid FROM pg_roles WHERE rolname = current_user)),
    (SELECT n_dead_tup FROM pg_stat_user_tables WHERE relid = 'plain.timeline'::regclass),
    :size0, pg_total_relation_size('plain.timeline');
