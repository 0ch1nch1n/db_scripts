-- Healthy records are aggregated per schema/type; only review items retain names.
@@common.sql &1 &2 &3 &4 &5 &6 &7 &8
WITH reviewed AS (
SELECT st.owner, st.index_name, st.table_owner, st.table_name,
       st.object_type, st.partition_name, st.subpartition_name,
       TO_CHAR(st.last_analyzed,'YYYY-MM-DD HH24:MI:SS') last_analyzed,
       st.stale_stats, st.stattype_locked, st.scope,
       CASE WHEN st.object_type='SUBPARTITION' THEN sp.status
            WHEN st.object_type='PARTITION' THEN p.status ELSE i.status END index_status,
       CASE WHEN CASE WHEN st.object_type='SUBPARTITION' THEN sp.status
                      WHEN st.object_type='PARTITION' THEN p.status ELSE i.status END='UNUSABLE' THEN 'INDEX_UNUSABLE'
            WHEN CASE WHEN st.object_type='SUBPARTITION' THEN sp.status
                      WHEN st.object_type='PARTITION' THEN p.status ELSE i.status END IS NULL THEN 'INDEX_STATUS_UNKNOWN'
            WHEN i.index_type NOT IN ('NORMAL','NORMAL/REV','BITMAP') THEN 'SPECIAL_INDEX_REVIEW'
            WHEN st.last_analyzed IS NULL THEN 'MISSING_STATS'
            WHEN st.stale_stats='YES' THEN 'STALE_STATS'
            WHEN st.stale_stats='NO' THEN 'OK' ELSE 'UNKNOWN' END review_status
  FROM dba_ind_statistics st
  JOIN dba_users u ON u.username=st.owner AND u.oracle_maintained='N'
  JOIN dba_indexes i ON i.owner=st.owner AND i.index_name=st.index_name
  LEFT JOIN dba_ind_partitions p ON st.object_type='PARTITION'
       AND p.index_owner=st.owner AND p.index_name=st.index_name AND p.partition_name=st.partition_name
  LEFT JOIN dba_ind_subpartitions sp ON st.object_type='SUBPARTITION'
       AND sp.index_owner=st.owner AND sp.index_name=st.index_name AND sp.subpartition_name=st.subpartition_name
), flagged AS (
    SELECT r.*,CASE WHEN review_status<>'OK' OR stattype_locked IS NOT NULL THEN 1 ELSE 0 END needs_review
      FROM reviewed r
), compact AS (
    SELECT owner,object_type,
           CASE WHEN needs_review=1 THEN 'DETAIL' ELSE 'SUMMARY' END record_type,
           CASE WHEN needs_review=1 THEN index_name END index_name,
           CASE WHEN needs_review=1 THEN table_owner END table_owner,
           CASE WHEN needs_review=1 THEN table_name END table_name,
           CASE WHEN needs_review=1 THEN partition_name END partition_name,
           CASE WHEN needs_review=1 THEN subpartition_name END subpartition_name,
           CASE WHEN needs_review=1 THEN last_analyzed END last_analyzed,
           CASE WHEN needs_review=1 THEN stale_stats END stale_stats,
           CASE WHEN needs_review=1 THEN stattype_locked END stattype_locked,
           CASE WHEN needs_review=1 THEN scope END scope,
           CASE WHEN needs_review=1 THEN index_status END index_status,
           review_status
      FROM flagged
)
SELECT '&db_label' database_label,owner,object_type,record_type,index_name,table_owner,table_name,partition_name,subpartition_name,last_analyzed,stale_stats,stattype_locked,scope,index_status,review_status,COUNT(*) object_count
  FROM compact
 GROUP BY owner,object_type,record_type,index_name,table_owner,table_name,partition_name,subpartition_name,last_analyzed,stale_stats,stattype_locked,scope,index_status,review_status
 ORDER BY owner,object_type,record_type;
exit success rollback
