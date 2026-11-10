-- Run once in the ERP database with the database owner's approval.
-- Grant only SELECT and INSERT on this table to the dedicated probe role.
-- Each controlled observation inserts one UUID; arrange retention separately.
CREATE TABLE IF NOT EXISTS public.andeslog_replication_probes (
    probe_id uuid PRIMARY KEY,
    inserted_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
