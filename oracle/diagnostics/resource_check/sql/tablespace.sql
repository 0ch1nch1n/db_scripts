@@common.sql &1 &2 &3 &4 &5 &6 &7 &8
WITH files AS (
    SELECT tablespace_name, SUM(bytes) current_bytes,
           SUM(CASE WHEN autoextensible='YES' THEN GREATEST(bytes,maxbytes) ELSE bytes END) configured_max_bytes
      FROM dba_data_files GROUP BY tablespace_name
), free AS (
    SELECT tablespace_name, SUM(bytes) free_bytes FROM dba_free_space GROUP BY tablespace_name
), temp_files AS (
    SELECT tablespace_name, SUM(bytes) current_bytes,
           SUM(CASE WHEN autoextensible='YES' THEN GREATEST(bytes,maxbytes) ELSE bytes END) configured_max_bytes
      FROM dba_temp_files GROUP BY tablespace_name
), temp_free AS (
    -- May have multiple instance-local temporary tablespace rows; aggregate once here.
    SELECT tablespace_name, SUM(free_space) free_bytes, SUM(tablespace_size) capacity_bytes
      FROM dba_temp_free_space GROUP BY tablespace_name
), space_rows AS (
    SELECT t.tablespace_name, t.contents tablespace_type, t.status tablespace_status,
           f.current_bytes, f.configured_max_bytes,
           CASE WHEN t.contents='PERMANENT' AND t.status='ONLINE' THEN f.current_bytes-NVL(s.free_bytes,0) END used_bytes,
           CASE WHEN t.contents='PERMANENT' AND t.status='ONLINE' THEN NVL(s.free_bytes,0) END free_bytes,
           CASE WHEN t.contents='UNDO' THEN 'SEE_UNDO_REPORT'
                WHEN t.status<>'ONLINE' THEN 'NON_ONLINE_REVIEW' ELSE 'DATAFILE_FREE_EXTENTS' END usage_method
      FROM dba_tablespaces t JOIN files f ON f.tablespace_name=t.tablespace_name
      LEFT JOIN free s ON s.tablespace_name=t.tablespace_name
    UNION ALL
    SELECT t.tablespace_name, t.contents, t.status, f.current_bytes, f.configured_max_bytes,
           CASE WHEN s.capacity_bytes=f.current_bytes THEN f.current_bytes-s.free_bytes END,
           CASE WHEN s.capacity_bytes=f.current_bytes THEN s.free_bytes END,
           CASE WHEN s.capacity_bytes=f.current_bytes THEN 'TEMP_FREE_INCLUDES_REUSABLE'
                ELSE 'TEMP_CAPACITY_MISMATCH_REVIEW' END
      FROM dba_tablespaces t JOIN temp_files f ON f.tablespace_name=t.tablespace_name
      LEFT JOIN temp_free s ON s.tablespace_name=t.tablespace_name
), scored AS (
    SELECT r.*, used_bytes/NULLIF(current_bytes,0)*100 pct_current,
           used_bytes/NULLIF(configured_max_bytes,0)*100 pct_max FROM space_rows r
)
SELECT '&db_label' database_label, tablespace_name, tablespace_type, tablespace_status,
       ROUND(current_bytes/POWER(1024,3),4) current_gb,
       ROUND(used_bytes/POWER(1024,3),4) used_gb,
       ROUND(free_bytes/POWER(1024,3),4) reusable_or_free_gb,
       ROUND(configured_max_bytes/POWER(1024,3),4) configured_max_gb,
       ROUND(pct_current,4) used_pct_current, ROUND(pct_max,4) used_pct_max,
       '&alert_basis' alert_basis, &threshold alert_threshold,
       usage_method,
       CASE WHEN tablespace_type='UNDO' THEN 'SEE_UNDO_REPORT'
            WHEN used_bytes IS NULL OR used_bytes<0 OR used_bytes>current_bytes OR tablespace_status<>'ONLINE' THEN 'REVIEW'
            WHEN CASE WHEN '&alert_basis'='MAX' THEN pct_max ELSE pct_current END > &threshold THEN 'ALERT'
            ELSE 'OK' END review_status
  FROM scored ORDER BY tablespace_type,tablespace_name;
exit success rollback
