-- Runs from root. Never reads remote-instance DBA_UNDO_EXTENTS states.
@@common.sql &1 &2 &3 &4 &5 &6 &7 &8
WITH context AS (
    SELECT d.cdb,
           (SELECT MAX(property_value) FROM database_properties
             WHERE property_name='LOCAL_UNDO_ENABLED') local_undo,
           CASE WHEN d.cdb='NO' THEN 0
                WHEN UPPER('&target_pdb')='CDBROOT' THEN 1
                ELSE (SELECT con_id FROM v$containers WHERE name=UPPER('&target_pdb')) END requested_con_id
      FROM v$database d
), scope AS (
    SELECT c.*,
           CASE WHEN cdb='YES' AND UPPER(local_undo)='FALSE' THEN 1 ELSE requested_con_id END undo_con_id,
           CASE WHEN cdb='NO' THEN 'NON_CDB'
                WHEN UPPER(local_undo)='FALSE' THEN 'CDB_SHARED'
                WHEN UPPER(local_undo)='TRUE' THEN 'LOCAL_CONTAINER'
                ELSE 'UNDO_MODE_UNKNOWN' END undo_scope
      FROM context c
), recent AS (
    SELECT u.*, ROW_NUMBER() OVER(PARTITION BY u.inst_id
               ORDER BY CASE WHEN u.con_id=s.undo_con_id THEN 0 ELSE 1 END,
                        u.begin_time DESC,u.end_time DESC) rn
      FROM gv$undostat u CROSS JOIN scope s
     WHERE u.con_id=s.undo_con_id OR (s.undo_scope='CDB_SHARED' AND u.con_id=0)
), file_size AS (
    SELECT con_id,tablespace_name,SUM(bytes) current_bytes,
           SUM(CASE WHEN autoextensible='YES' THEN GREATEST(bytes,maxbytes) ELSE bytes END) max_bytes
      FROM cdb_data_files GROUP BY con_id,tablespace_name
), data AS (
    SELECT i.inst_id,i.instance_name,s.undo_scope,s.undo_con_id,s.requested_con_id,u.con_id sample_con_id,
           u.begin_time,u.end_time,u.activeblks,u.unexpiredblks,u.expiredblks,
           u.ssolderrcnt,u.nospaceerrcnt,u.unxpstealcnt,u.tuned_undoretention,
           ts.name tablespace_name,t.block_size,f.current_bytes,f.max_bytes,
           CASE WHEN s.cdb='YES' AND s.requested_con_id>1 AND NOT EXISTS
                (SELECT 1 FROM gv$pdbs p WHERE p.inst_id=i.inst_id AND p.con_id=s.requested_con_id
                  AND p.open_mode IN ('READ WRITE','READ ONLY')) THEN 0 ELSE 1 END pdb_open
      FROM gv$instance i CROSS JOIN scope s
      LEFT JOIN recent u ON u.inst_id=i.inst_id AND u.rn=1
      LEFT JOIN v$tablespace ts ON ts.ts#=u.undotsn AND ts.con_id=s.undo_con_id
      LEFT JOIN cdb_tablespaces t ON t.con_id=ts.con_id AND t.tablespace_name=ts.name AND t.contents='UNDO'
      LEFT JOIN file_size f ON f.con_id=t.con_id AND f.tablespace_name=t.tablespace_name
)
SELECT '&db_label' database_label,inst_id,instance_name,undo_scope,undo_con_id,sample_con_id,
       tablespace_name,
       TO_CHAR(begin_time,'YYYY-MM-DD HH24:MI:SS') sample_begin_dbtime,
       TO_CHAR(end_time,'YYYY-MM-DD HH24:MI:SS') sample_end_dbtime,
       ROUND((SYSDATE-end_time)*1440,2) sample_age_minutes,
       ROUND(current_bytes/POWER(1024,3),4) current_gb,
       ROUND(max_bytes/POWER(1024,3),4) configured_max_gb,
       ROUND(activeblks*block_size/POWER(1024,3),4) active_gb,
       ROUND(unexpiredblks*block_size/POWER(1024,3),4) unexpired_gb,
       ROUND(expiredblks*block_size/POWER(1024,3),4) expired_reusable_gb,
       ROUND((activeblks+unexpiredblks)*block_size/NULLIF(current_bytes,0)*100,4) retained_pct_current,
       ROUND((activeblks+unexpiredblks)*block_size/NULLIF(max_bytes,0)*100,4) retained_pct_max,
       ssolderrcnt,nospaceerrcnt,unxpstealcnt,tuned_undoretention,
       CASE WHEN pdb_open=0 AND undo_scope='LOCAL_CONTAINER' THEN 'PDB_NOT_OPEN'
            WHEN undo_scope='UNDO_MODE_UNKNOWN' OR end_time IS NULL OR current_bytes IS NULL
              OR (SYSDATE-end_time)*1440>30 THEN 'REVIEW'
            WHEN nospaceerrcnt>0 OR ssolderrcnt>0 OR unxpstealcnt>0 THEN 'ALERT'
            WHEN (activeblks+unexpiredblks)*block_size/NULLIF(
                 CASE WHEN '&alert_basis'='MAX' THEN max_bytes ELSE current_bytes END,0)*100>&threshold THEN 'REVIEW'
            ELSE 'OK' END review_status
  FROM data ORDER BY inst_id;
exit success rollback
