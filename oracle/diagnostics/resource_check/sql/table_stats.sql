@@common.sql &1 &2 &3 &4 &5 &6 &7 &8
SELECT '&db_label' database_label, st.owner, st.table_name, st.object_type,
       st.partition_name, st.subpartition_name, st.num_rows, st.blocks,
       TO_CHAR(st.last_analyzed,'YYYY-MM-DD HH24:MI:SS') last_analyzed,
       st.stale_stats, st.stattype_locked, st.scope,
       t.temporary, t.external, t.partitioned,
       CASE WHEN t.temporary='Y' OR t.external='YES' THEN 'SPECIAL_OBJECT_REVIEW'
            WHEN st.last_analyzed IS NULL THEN 'MISSING_STATS'
            WHEN st.stale_stats='YES' THEN 'STALE_STATS'
            WHEN st.stale_stats='NO' THEN 'OK' ELSE 'UNKNOWN' END review_status
  FROM dba_tab_statistics st
  JOIN dba_users u ON u.username=st.owner AND u.oracle_maintained='N'
  JOIN dba_tables t ON t.owner=st.owner AND t.table_name=st.table_name
 ORDER BY st.owner,st.table_name,st.object_type,st.partition_name,st.subpartition_name;
exit success rollback
