-- Structural metrics and allocation trends, NOT a measured fragmentation percentage.
@@common.sql &1 &2 &3 &4 &5 &6 &7 &8
SELECT '&db_label' database_label,s.owner,s.segment_name index_name,s.partition_name,
       s.segment_type,s.tablespace_name,o.object_id,o.data_object_id,
       TO_CHAR(o.last_ddl_time,'YYYY-MM-DD HH24:MI:SS') last_ddl_time,
       i.table_owner,i.table_name,i.index_type,
       CASE WHEN s.segment_type='INDEX SUBPARTITION' THEN sp.status
            WHEN s.segment_type='INDEX PARTITION' THEN p.status ELSE i.status END index_status,
       ROUND(s.bytes/POWER(1024,2),4) segment_mb,s.blocks segment_blocks,
       st.num_rows,st.blevel,st.leaf_blocks,st.clustering_factor,
       TO_CHAR(st.last_analyzed,'YYYY-MM-DD HH24:MI:SS') last_analyzed,
       NVL(st.stale_stats,'UNKNOWN') stale_stats,
       'STRUCTURAL_TREND_ONLY' measurement_method
  FROM dba_segments s JOIN dba_users u ON u.username=s.owner AND u.oracle_maintained='N'
  JOIN dba_indexes i ON i.owner=s.owner AND i.index_name=s.segment_name
  LEFT JOIN dba_ind_partitions p ON s.segment_type='INDEX PARTITION'
       AND p.index_owner=s.owner AND p.index_name=s.segment_name AND p.partition_name=s.partition_name
  LEFT JOIN dba_ind_subpartitions sp ON s.segment_type='INDEX SUBPARTITION'
       AND sp.index_owner=s.owner AND sp.index_name=s.segment_name AND sp.subpartition_name=s.partition_name
  LEFT JOIN dba_ind_statistics st ON st.owner=s.owner AND st.index_name=s.segment_name
       AND ((s.segment_type='INDEX' AND st.object_type='INDEX')
         OR (s.segment_type='INDEX PARTITION' AND st.object_type='PARTITION' AND st.partition_name=s.partition_name)
         OR (s.segment_type='INDEX SUBPARTITION' AND st.object_type='SUBPARTITION' AND st.subpartition_name=s.partition_name))
  LEFT JOIN dba_objects o ON o.owner=s.owner AND o.object_name=s.segment_name
       AND o.object_type=s.segment_type
       AND (o.subobject_name=s.partition_name OR (o.subobject_name IS NULL AND s.partition_name IS NULL))
 WHERE s.segment_type IN ('INDEX','INDEX PARTITION','INDEX SUBPARTITION')
 ORDER BY s.owner,s.segment_name,s.partition_name;
exit success rollback
