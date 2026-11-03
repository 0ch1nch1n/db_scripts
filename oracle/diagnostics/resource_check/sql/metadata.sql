@@common.sql &1 &2 &3 &4 &5 &6 &7 &8
SELECT '&db_label' database_label, d.dbid, d.name db_name, d.db_unique_name,
       SYS_CONTEXT('USERENV','CON_NAME') container_name,
       SYS_CONTEXT('USERENV','CON_ID') con_id,
       CASE WHEN d.cdb='NO' THEN d.dbid ELSE
           (SELECT dbid FROM v$containers
             WHERE con_id=TO_NUMBER(SYS_CONTEXT('USERENV','CON_ID'))) END container_dbid,
       d.database_role, d.open_mode database_open_mode,
       i.instance_name, i.host_name, i.version,
       TO_CHAR(SYSTIMESTAMP AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SSTZH:TZM') collected_at_utc
  FROM v$database d CROSS JOIN v$instance i;
exit success rollback
