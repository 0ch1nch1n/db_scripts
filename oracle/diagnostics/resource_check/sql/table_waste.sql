-- Only reliable ordinary heap-table estimates; candidates plus coverage counts.
-- Capture extra arguments before common.sql changes positional substitutions.
set echo off
set verify off
define waste_mb = '&9'
define waste_pct = '&10'
@@common.sql &1 &2 &3 &4 &5 &6 &7 &8
WITH inventory AS (
    SELECT t.owner,t.table_name,t.tablespace_name,t.num_rows,t.avg_row_len,
           NVL(t.pct_free,10) pct_free,ts.block_size,
           TO_CHAR(st.last_analyzed,'YYYY-MM-DD HH24:MI:SS') last_analyzed,
           NVL(st.stale_stats,'UNKNOWN') stale_stats,
           CASE WHEN t.partitioned='YES' THEN 'UNSUPPORTED_PARTITIONED'
                WHEN t.temporary='Y' OR t.external='YES' OR t.secondary='Y' OR t.nested='YES'
                  OR t.iot_type IS NOT NULL OR t.cluster_name IS NOT NULL THEN 'UNSUPPORTED_TABLE_TYPE'
                WHEN NVL(t.compression,'UNKNOWN')<>'DISABLED' THEN 'UNSUPPORTED_COMPRESSED'
                WHEN NVL(t.segment_created,'NO')<>'YES' THEN 'NO_TABLE_SEGMENT'
                WHEN st.last_analyzed IS NULL OR NVL(st.stale_stats,'UNKNOWN')<>'NO'
                  THEN 'UNRELIABLE_STATS'
                WHEN t.num_rows IS NULL OR t.avg_row_len IS NULL OR ts.block_size IS NULL
                  OR NVL(t.pct_free,10)>=100 OR NVL(t.pct_free,10)<0 THEN 'MISSING_INPUT_STATS'
                ELSE 'ESTIMATED' END method_status
      FROM dba_tables t JOIN dba_users u ON u.username=t.owner AND u.oracle_maintained='N'
      LEFT JOIN dba_tablespaces ts ON ts.tablespace_name=t.tablespace_name
      LEFT JOIN dba_tab_statistics st ON st.owner=t.owner AND st.table_name=t.table_name
           AND st.object_type='TABLE' AND st.partition_name IS NULL AND st.subpartition_name IS NULL
           AND (st.scope='SHARED' OR st.scope IS NULL)
), segments AS (
    SELECT s.owner,s.segment_name,SUM(s.blocks) segment_blocks,SUM(s.bytes) segment_bytes
      FROM dba_segments s JOIN inventory i ON i.owner=s.owner AND i.table_name=s.segment_name
           AND i.method_status='ESTIMATED'
     WHERE s.segment_type='TABLE'
     GROUP BY s.owner,s.segment_name
), estimated AS (
    SELECT i.*,s.segment_blocks,s.segment_bytes,
           CASE WHEN i.method_status='ESTIMATED' THEN
             CEIL(i.num_rows*i.avg_row_len/NULLIF(i.block_size*(1-i.pct_free/100.0),0)) END est_blocks,
           CASE WHEN i.method_status='ESTIMATED' AND NVL(s.segment_bytes,0)<=0
                THEN 'NO_TABLE_SEGMENT' ELSE i.method_status END final_method
      FROM inventory i LEFT JOIN segments s ON s.owner=i.owner AND s.segment_name=i.table_name
), measured AS (
    SELECT e.*,
           ROUND(segment_bytes/POWER(1024,2),4) segment_mb,
           CASE WHEN final_method='ESTIMATED' THEN
             ROUND(GREATEST(segment_blocks-est_blocks,0)*block_size/POWER(1024,2),4) END estimated_waste_mb,
           CASE WHEN final_method='ESTIMATED' THEN
             ROUND(GREATEST(segment_blocks-est_blocks,0)*100.0/NULLIF(segment_blocks,0),4) END estimated_unused_pct
      FROM estimated e
), classified AS (
    SELECT m.*,CASE WHEN final_method='ESTIMATED' AND estimated_waste_mb>&waste_mb
                    AND estimated_unused_pct>&waste_pct THEN 1 ELSE 0 END candidate
      FROM measured m
), compact AS (
    SELECT owner,final_method method_status,
           CASE WHEN candidate=1 THEN 'DETAIL' ELSE 'SUMMARY' END record_type,
           CASE WHEN candidate=1 THEN table_name END table_name,
           CASE WHEN candidate=1 THEN tablespace_name END tablespace_name,
           CASE WHEN candidate=1 THEN segment_mb END segment_mb,
           CASE WHEN candidate=1 THEN estimated_waste_mb END estimated_waste_mb,
           CASE WHEN candidate=1 THEN estimated_unused_pct END estimated_unused_pct,
           CASE WHEN candidate=1 THEN last_analyzed END last_analyzed,
           CASE WHEN candidate=1 THEN stale_stats END stale_stats
      FROM classified
)
SELECT '&db_label' database_label,owner,method_status,record_type,table_name,tablespace_name,
       segment_mb,estimated_waste_mb,estimated_unused_pct,last_analyzed,stale_stats,COUNT(*) object_count
  FROM compact
 GROUP BY owner,method_status,record_type,table_name,tablespace_name,
          segment_mb,estimated_waste_mb,estimated_unused_pct,last_analyzed,stale_stats
 ORDER BY owner,method_status,record_type;
exit success rollback
