-- Healthy records are aggregated per schema/type; only review items retain names.
@@common.sql &1 &2 &3 &4 &5 &6 &7 &8
WITH reviewed AS (
SELECT st.owner, st.table_name, st.object_type,
       st.partition_name, st.subpartition_name,
       TO_CHAR(st.last_analyzed,'YYYY-MM-DD HH24:MI:SS') last_analyzed,
       st.stale_stats, st.stattype_locked, st.scope,
       CASE WHEN t.temporary='Y' OR t.external='YES' THEN 'SPECIAL_OBJECT_REVIEW'
            WHEN st.last_analyzed IS NULL THEN 'MISSING_STATS'
            WHEN st.stale_stats='YES' THEN 'STALE_STATS'
            WHEN st.stale_stats='NO' THEN 'OK' ELSE 'UNKNOWN' END review_status
  FROM dba_tab_statistics st
  JOIN dba_users u ON u.username=st.owner AND u.oracle_maintained='N'
  JOIN dba_tables t ON t.owner=st.owner AND t.table_name=st.table_name
), flagged AS (
    SELECT r.*,CASE WHEN review_status<>'OK' OR stattype_locked IS NOT NULL THEN 1 ELSE 0 END needs_review
      FROM reviewed r
), compact AS (
    SELECT owner,object_type,
           CASE WHEN needs_review=1 THEN 'DETAIL' ELSE 'SUMMARY' END record_type,
           CASE WHEN needs_review=1 THEN table_name END table_name,
           CASE WHEN needs_review=1 THEN partition_name END partition_name,
           CASE WHEN needs_review=1 THEN subpartition_name END subpartition_name,
           CASE WHEN needs_review=1 THEN last_analyzed END last_analyzed,
           CASE WHEN needs_review=1 THEN stale_stats END stale_stats,
           CASE WHEN needs_review=1 THEN stattype_locked END stattype_locked,
           CASE WHEN needs_review=1 THEN scope END scope,
           review_status
      FROM flagged
)
SELECT '&db_label' database_label,owner,object_type,record_type,table_name,partition_name,subpartition_name,last_analyzed,stale_stats,stattype_locked,scope,review_status,COUNT(*) object_count
  FROM compact
 GROUP BY owner,object_type,record_type,table_name,partition_name,subpartition_name,last_analyzed,stale_stats,stattype_locked,scope,review_status
 ORDER BY owner,object_type,record_type;
exit success rollback
