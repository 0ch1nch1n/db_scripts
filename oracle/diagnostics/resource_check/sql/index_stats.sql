@@common.sql &1 &2 &3 &4 &5 &6 &7 &8
SELECT '&db_label' database_label, st.owner, st.index_name, st.table_owner, st.table_name,
       st.object_type, st.partition_name, st.subpartition_name,
       TO_CHAR(st.last_analyzed,'YYYY-MM-DD HH24:MI:SS') last_analyzed,
       st.stale_stats, st.stattype_locked, st.num_rows, st.blevel, st.leaf_blocks, st.clustering_factor,
       i.index_type,
       CASE WHEN st.object_type='SUBPARTITION' THEN sp.status
            WHEN st.object_type='PARTITION' THEN p.status ELSE i.status END index_status,
       CASE WHEN CASE WHEN st.object_type='SUBPARTITION' THEN sp.status
                      WHEN st.object_type='PARTITION' THEN p.status ELSE i.status END='UNUSABLE' THEN 'INDEX_UNUSABLE'
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
 ORDER BY st.owner,st.index_name,st.object_type,st.partition_name,st.subpartition_name;
exit success rollback
