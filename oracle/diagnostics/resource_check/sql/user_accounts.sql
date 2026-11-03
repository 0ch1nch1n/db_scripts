@@common.sql &1 &2 &3 &4 &5 &6 &7 &8
SELECT '&db_label' database_label, username, account_status,
       TO_CHAR(expiry_date,'YYYY-MM-DD HH24:MI:SS') expiry_date,
       FLOOR(expiry_date-SYSDATE) expiry_days_remaining,
       TO_CHAR(lock_date,'YYYY-MM-DD HH24:MI:SS') lock_date,
       profile, authentication_type, common, proxy_only_connect,
       TO_CHAR(last_login AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SSTZH:TZM') last_login_utc
  FROM dba_users WHERE oracle_maintained='N' ORDER BY username;
exit success rollback
