-- Put source.csv and target.csv in the current working directory.
-- All comparison objects are temporary. Any accessible PostgreSQL 12+ DB works.
\set ON_ERROR_STOP on
\set ECHO none
\set QUIET on
\pset pager off
\pset null '(NULL)'
\encoding UTF8
\if :{?report_file}
\else
  \set report_file 'comparison.txt'
\endif
\if :{?diff_file}
\else
  \set diff_file 'differences.csv'
\endif
\if :{?strict}
\else
  \set strict false
\endif
\o :report_file
\o
\o :diff_file
\o
BEGIN;
SET LOCAL search_path=pg_catalog;
CREATE TEMP TABLE verify_source (
 record_type text NOT NULL,schema_name text NOT NULL,object_type text NOT NULL,
 object_name text NOT NULL,signature text NOT NULL,details jsonb NOT NULL,
 PRIMARY KEY(record_type,schema_name,object_type,object_name,signature)
) ON COMMIT DROP;
CREATE TEMP TABLE verify_target (LIKE pg_temp.verify_source INCLUDING ALL) ON COMMIT DROP;
-- psql \copy does NOT interpolate variables. Edit these two literal paths if needed.
\copy pg_temp.verify_source FROM 'source.csv' WITH (FORMAT csv,HEADER true)
\copy pg_temp.verify_target FROM 'target.csv' WITH (FORMAT csv,HEADER true)

DO $validate$
DECLARE t text; n bigint; expected bigint; meta jsonb;
BEGIN
  FOREACH t IN ARRAY ARRAY['verify_source','verify_target'] LOOP
    EXECUTE format('SELECT count(*) FROM pg_temp.%I WHERE record_type=''META''',t) INTO n;
    IF n<>1 THEN RAISE EXCEPTION '%: invalid/missing metadata',t; END IF;
    EXECUTE format('SELECT details FROM pg_temp.%I WHERE record_type=''META''',t) INTO meta;
    IF meta->>'format_version' IS DISTINCT FROM '1' THEN
      RAISE EXCEPTION '%: unsupported snapshot format',t;
    END IF;
    EXECUTE format('SELECT count(*) FROM pg_temp.%I WHERE record_type=''ZZ_END''',t) INTO n;
    IF n<>1 THEN RAISE EXCEPTION '%: incomplete snapshot (missing completion record)',t; END IF;
    EXECUTE format('SELECT (details->>''record_count'')::bigint FROM pg_temp.%I
                    WHERE record_type=''ZZ_END''',t) INTO expected;
    EXECUTE format('SELECT count(*)-1 FROM pg_temp.%I',t) INTO n;
    IF expected IS NULL OR expected<>n THEN RAISE EXCEPTION '%: snapshot record count mismatch',t; END IF;
  END LOOP;
  IF (SELECT details->'schemas' FROM pg_temp.verify_source WHERE record_type='META')
     IS DISTINCT FROM
     (SELECT details->'schemas' FROM pg_temp.verify_target WHERE record_type='META') THEN
    RAISE EXCEPTION 'Schema lists differ. Compare the same schemas on both sides.';
  END IF;
END
$validate$;

CREATE TEMP TABLE verify_differences ON COMMIT DROP AS
SELECT
  CASE WHEN coalesce(s.details->>'status','')='ERROR'
         OR coalesce(t.details->>'status','')='ERROR' THEN 'ERROR'
       WHEN coalesce(s.record_type,t.record_type) IN ('SECURITY','ENVIRONMENT','HEALTH','STATE') THEN 'REVIEW'
       ELSE 'DIFF' END AS severity,
  CASE WHEN s.record_type IS NULL THEN 'TARGET_ONLY'
       WHEN t.record_type IS NULL THEN 'SOURCE_ONLY' ELSE 'CHANGED' END AS difference,
  coalesce(s.record_type,t.record_type) AS record_type,
  coalesce(s.schema_name,t.schema_name) AS schema_name,
  coalesce(s.object_type,t.object_type) AS object_type,
  coalesce(s.object_name,t.object_name) AS object_name,
  coalesce(s.signature,t.signature) AS signature,
  s.details AS source_details,t.details AS target_details
FROM pg_temp.verify_source s FULL JOIN pg_temp.verify_target t
USING(record_type,schema_name,object_type,object_name,signature)
WHERE coalesce(s.record_type,t.record_type) NOT IN ('META','ZZ_END')
  AND (s.details IS DISTINCT FROM t.details
       OR s.details->>'status'='ERROR' OR t.details->>'status'='ERROR'
       OR coalesce(s.record_type,t.record_type)='HEALTH');

-- Explicitly surface untested data/configuration and environment differences.
INSERT INTO pg_temp.verify_differences
SELECT 'REVIEW','CONFIGURATION','CONFIG','','COLLECTION_OPTIONS','','',s.details,t.details
FROM pg_temp.verify_source s CROSS JOIN pg_temp.verify_target t
WHERE s.record_type='META' AND t.record_type='META'
  AND (s.details->'check_rows' IS DISTINCT FROM t.details->'check_rows'
       OR s.details->'check_data' IS DISTINCT FROM t.details->'check_data');
INSERT INTO pg_temp.verify_differences
SELECT 'REVIEW','ENVIRONMENT','CONFIG','','DATABASE_ENVIRONMENT','','',
  jsonb_build_object('version',s.details->'server_version','encoding',s.details->'database_encoding',
      'collation',s.details->'database_collation','ctype',s.details->'database_ctype'),
  jsonb_build_object('version',t.details->'server_version','encoding',t.details->'database_encoding',
      'collation',t.details->'database_collation','ctype',t.details->'database_ctype')
FROM pg_temp.verify_source s CROSS JOIN pg_temp.verify_target t
WHERE s.record_type='META' AND t.record_type='META'
  AND (s.details->'server_version' IS DISTINCT FROM t.details->'server_version'
    OR s.details->'database_encoding' IS DISTINCT FROM t.details->'database_encoding'
    OR s.details->'database_collation' IS DISTINCT FROM t.details->'database_collation'
    OR s.details->'database_ctype' IS DISTINCT FROM t.details->'database_ctype');

\o :diff_file
COPY (SELECT * FROM pg_temp.verify_differences
      ORDER BY severity,record_type,schema_name,object_type,object_name,signature)
TO STDOUT WITH (FORMAT csv,HEADER true);
\o
\o :report_file
\qecho PostgreSQL schema migration verification v1.0
\qecho ==== Collection metadata: verify database names and capture times ====
SELECT 'SOURCE' AS side,details FROM pg_temp.verify_source WHERE record_type='META'
UNION ALL
SELECT 'TARGET',details FROM pg_temp.verify_target WHERE record_type='META';
\qecho ==== Data coverage (NOT_RUN means no content/row verification) ====
SELECT 'SOURCE' AS side,
       CASE WHEN (details->>'check_rows')::boolean OR (details->>'check_data')::boolean
            THEN 'ENABLED' ELSE 'NOT_RUN' END AS exact_row_counts,
       CASE WHEN (details->>'check_data')::boolean THEN 'ENABLED' ELSE 'NOT_RUN' END AS content_fingerprints
FROM pg_temp.verify_source WHERE record_type='META'
UNION ALL
SELECT 'TARGET',
       CASE WHEN (details->>'check_rows')::boolean OR (details->>'check_data')::boolean
            THEN 'ENABLED' ELSE 'NOT_RUN' END,
       CASE WHEN (details->>'check_data')::boolean THEN 'ENABLED' ELSE 'NOT_RUN' END
FROM pg_temp.verify_target WHERE record_type='META';
\qecho ==== Object counts (STRUCTURE excludes supporting column/definition records) ====
SELECT coalesce(s.schema_name,t.schema_name) AS schema_name,
       coalesce(s.object_type,t.object_type) AS object_type,
       coalesce(s.n,0) AS source_count,coalesce(t.n,0) AS target_count
FROM (SELECT schema_name,object_type,count(*) n FROM pg_temp.verify_source
      WHERE record_type='STRUCTURE' AND object_type NOT IN ('COLUMN','SEQUENCE_DEFINITION','FOREIGN_TABLE_OPTIONS')
      GROUP BY 1,2) s
FULL JOIN (SELECT schema_name,object_type,count(*) n FROM pg_temp.verify_target
      WHERE record_type='STRUCTURE' AND object_type NOT IN ('COLUMN','SEQUENCE_DEFINITION','FOREIGN_TABLE_OPTIONS')
      GROUP BY 1,2) t USING(schema_name,object_type)
ORDER BY 1,2;
\qecho ==== Differences summary ====
SELECT severity,record_type,count(*) FROM pg_temp.verify_differences GROUP BY 1,2 ORDER BY 1,2;
\qecho ==== Difference keys (full before/after details are in differences.csv) ====
SELECT severity,difference,record_type,schema_name,object_type,object_name,signature
FROM pg_temp.verify_differences ORDER BY 1,3,4,5,6,7;
\qecho ==== Automated result (limited to documented coverage) ====
SELECT CASE WHEN EXISTS (SELECT FROM pg_temp.verify_differences WHERE severity='ERROR') THEN 'ERROR'
            WHEN EXISTS (SELECT FROM pg_temp.verify_differences WHERE severity='DIFF') THEN 'DIFF'
            WHEN EXISTS (SELECT FROM pg_temp.verify_differences WHERE severity='REVIEW') THEN 'REVIEW'
            ELSE 'MATCH' END AS automated_result;
\qecho MATCH does not certify the entire migration. Review scope, timestamps and manual checks in README.
\o
SELECT EXISTS (SELECT FROM pg_temp.verify_differences) AS has_differences \gset
SELECT CASE WHEN EXISTS (SELECT FROM pg_temp.verify_differences WHERE severity='ERROR') THEN 'ERROR'
            WHEN EXISTS (SELECT FROM pg_temp.verify_differences WHERE severity='DIFF') THEN 'DIFF'
            WHEN EXISTS (SELECT FROM pg_temp.verify_differences WHERE severity='REVIEW') THEN 'REVIEW'
            ELSE 'MATCH' END AS automated_result;
ROLLBACK;
\echo 'Comparison finished. Report:' :report_file 'Details:' :diff_file
\if :strict
  \if :has_differences
    DO $$ BEGIN RAISE EXCEPTION 'Strict comparison: differences or review items found; see reports'; END $$;
  \endif
\endif
