-- Complete top-level table inventory; estimates only for supported ordinary heap tables.
-- LOB and index segments are not included in table segment size.
@@common.sql &1 &2 &3 &4 &5 &6 &7 &8
WITH segments AS (
    SELECT owner,segment_name,SUM(blocks) segment_blocks,SUM(bytes) segment_bytes
      FROM dba_segments WHERE segment_type IN ('TABLE','TABLE PARTITION','TABLE SUBPARTITION')
     GROUP BY owner,segment_name
), base AS (
    SELECT t.owner,t.table_name,t.tablespace_name,t.partitioned,t.compression,
           t.num_rows,t.avg_row_len,t.blocks stat_blocks,t.pct_free,
           s.segment_blocks,s.segment_bytes,ts.block_size,
           st.last_analyzed,NVL(st.stale_stats,'UNKNOWN') stale_stats,
           o.object_id,o.data_object_id, o.last_ddl_time,
           CASE WHEN t.partitioned='YES' THEN 'UNSUPPORTED_PARTITIONED'
                WHEN t.temporary='Y' OR t.external='YES' OR t.secondary='Y' OR t.nested='YES'
                  OR t.iot_type IS NOT NULL OR t.cluster_name IS NOT NULL THEN 'UNSUPPORTED_TABLE_TYPE'
                WHEN t.compression<>'DISABLED' THEN 'UNSUPPORTED_COMPRESSED'
                WHEN t.segment_created<>'YES' OR s.segment_bytes IS NULL THEN 'NO_TABLE_SEGMENT'
                WHEN t.num_rows IS NULL OR t.avg_row_len IS NULL OR t.pct_free>=100 THEN 'MISSING_INPUT_STATS'
                ELSE 'ESTIMATED' END method_status
      FROM dba_tables t JOIN dba_users u ON u.username=t.owner AND u.oracle_maintained='N'
      LEFT JOIN segments s ON s.owner=t.owner AND s.segment_name=t.table_name
      LEFT JOIN dba_tablespaces ts ON ts.tablespace_name=t.tablespace_name
      LEFT JOIN dba_tab_statistics st ON st.owner=t.owner AND st.table_name=t.table_name
           AND st.object_type='TABLE' AND st.partition_name IS NULL AND st.subpartition_name IS NULL
      LEFT JOIN dba_objects o ON o.owner=t.owner AND o.object_name=t.table_name AND o.object_type='TABLE'
), estimated AS (
    SELECT b.*, CASE WHEN method_status='ESTIMATED' THEN
        CEIL(num_rows*avg_row_len/NULLIF(block_size*(1-NVL(pct_free,10)/100),0)) END est_blocks
      FROM base b
)
SELECT '&db_label' database_label,owner,table_name,tablespace_name,object_id,data_object_id,
       TO_CHAR(last_ddl_time,'YYYY-MM-DD HH24:MI:SS') last_ddl_time,
       partitioned,compression,block_size,pct_free,num_rows,avg_row_len,stat_blocks,segment_blocks,
       ROUND(segment_bytes/POWER(1024,2),4) segment_mb,
       est_blocks,
       CASE WHEN est_blocks IS NOT NULL THEN ROUND(GREATEST(segment_blocks-est_blocks,0)*block_size/POWER(1024,2),4) END estimated_waste_mb,
       CASE WHEN est_blocks IS NOT NULL THEN ROUND(GREATEST(segment_blocks-est_blocks,0)/NULLIF(segment_blocks,0)*100,4) END estimated_unused_pct,
       TO_CHAR(last_analyzed,'YYYY-MM-DD HH24:MI:SS') last_analyzed,stale_stats,method_status
  FROM estimated ORDER BY owner,table_name;
exit success rollback
