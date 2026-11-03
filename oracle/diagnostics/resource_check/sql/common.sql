-- Internal include. Parameters are validated by check_resources.sh; do not call directly.
set echo off
set verify off
set feedback off
set heading on
set pagesize 50000
set linesize 32767
set trimspool on
set tab off
set serveroutput off
set markup csv on delimiter , quote on
set numwidth 40
whenever oserror exit failure rollback
whenever sqlerror exit failure rollback
define db_label = '&1'
define target_pdb = '&2'
define expected_db = '&3'
define expected_unique = '&4'
define threshold = '&5'
define alert_basis = '&6'
define expiry_days = '&7'
define collection_mode = '&8'
DECLARE
    actual_name VARCHAR2(128);
    actual_unique VARCHAR2(128);
    is_cdb VARCHAR2(3);
    found_pdb NUMBER;
BEGIN
    SELECT name, db_unique_name, cdb INTO actual_name, actual_unique, is_cdb FROM v$database;
    IF UPPER(actual_name) <> UPPER('&expected_db') THEN
        RAISE_APPLICATION_ERROR(-20001, 'Unexpected DB_NAME: ' || actual_name);
    END IF;
    IF '&expected_unique' <> 'ANY' AND UPPER(actual_unique) <> UPPER('&expected_unique') THEN
        RAISE_APPLICATION_ERROR(-20002, 'Unexpected DB_UNIQUE_NAME: ' || actual_unique);
    END IF;
    IF is_cdb = 'YES' AND SYS_CONTEXT('USERENV','CON_NAME') <> 'CDB$ROOT' THEN
        RAISE_APPLICATION_ERROR(-20003, 'Initial connection must be CDB root');
    END IF;
    IF UPPER('&target_pdb') <> 'CDBROOT' THEN
        IF is_cdb <> 'YES' THEN
            RAISE_APPLICATION_ERROR(-20004, 'PDB specified for a non-CDB');
        END IF;
        SELECT COUNT(*) INTO found_pdb FROM v$pdbs WHERE name = UPPER('&target_pdb');
        IF found_pdb <> 1 THEN
            RAISE_APPLICATION_ERROR(-20005, 'Target PDB not found');
        END IF;
        IF '&collection_mode' <> 'ROOT' THEN
            EXECUTE IMMEDIATE 'ALTER SESSION SET CONTAINER = ' || DBMS_ASSERT.SIMPLE_SQL_NAME('&target_pdb');
            IF SYS_CONTEXT('USERENV','CON_NAME') <> UPPER('&target_pdb') THEN
                RAISE_APPLICATION_ERROR(-20006, 'Container switch verification failed');
            END IF;
        END IF;
    END IF;
END;
/
alter session set nls_numeric_characters = '.,';
alter session set time_zone = '+00:00';
