-- 源库执行，生成DDL命令
-- 排除“pg_”和“rds”用户
-- 高权限role的授予需要review，确认是必须的权限就加上
-- 密码无法迁移，需要重新设置 ALTER ROLE "xxx" PASSWORD 'yyy';

WITH RECURSIVE
selected_roles AS (
    SELECT r.*
    FROM pg_catalog.pg_roles AS r
    WHERE r.rolname !~ '^(pg_|rds)'
      -- Optional allowlist; uncomment and replace the example names:
      -- AND r.rolname IN ('application_login', 'application_ro', 'application_rw')
),
membership_rows AS (
    SELECT
        parent.rolname AS granted_role,
        member.rolname AS member_role,
        m.admin_option,
        COALESCE(
            (pg_catalog.to_jsonb(m) ->> 'inherit_option')::boolean,
            member.rolinherit
        ) AS inherit_option,
        COALESCE(
            (pg_catalog.to_jsonb(m) ->> 'set_option')::boolean,
            true
        ) AS set_option,
        (sp.role_name IS NOT NULL) AS parent_selected,
        (sm.role_name IS NOT NULL) AS member_selected
    FROM pg_catalog.pg_auth_members AS m
    JOIN pg_catalog.pg_roles AS parent ON parent.oid = m.roleid
    JOIN pg_catalog.pg_roles AS member ON member.oid = m.member
    LEFT JOIN (
        SELECT rolname AS role_name FROM selected_roles
    ) AS sp ON sp.role_name = parent.rolname
    LEFT JOIN (
        SELECT rolname AS role_name FROM selected_roles
    ) AS sm ON sm.role_name = member.rolname
    WHERE sp.role_name IS NOT NULL OR sm.role_name IS NOT NULL
),
role_settings AS (
    SELECT
        r.rolname,
        s.setdatabase,
        d.datname,
        cfg.setting,
        pg_catalog.split_part(cfg.setting, '=', 1) AS parameter_name,
        pg_catalog.substr(
            cfg.setting,
            pg_catalog.strpos(cfg.setting, '=') + 1
        ) AS parameter_value
    FROM selected_roles AS r
    JOIN pg_catalog.pg_db_role_setting AS s ON s.setrole = r.oid
    LEFT JOIN pg_catalog.pg_database AS d ON d.oid = s.setdatabase
    CROSS JOIN LATERAL pg_catalog.unnest(s.setconfig) AS cfg(setting)
    WHERE s.setdatabase = 0
       OR s.setdatabase = (
            SELECT oid
            FROM pg_catalog.pg_database
            WHERE datname = pg_catalog.current_database()
       )
),
generated AS (
    SELECT 10 AS section_no, r.rolname AS item_name,
           pg_catalog.format(
               'CREATE ROLE %I WITH %s %s %s %s %s %s %s CONNECTION LIMIT %s%s;',
               r.rolname,
               CASE WHEN r.rolsuper       THEN 'SUPERUSER'   ELSE 'NOSUPERUSER'   END,
               CASE WHEN r.rolinherit     THEN 'INHERIT'     ELSE 'NOINHERIT'     END,
               CASE WHEN r.rolcreaterole  THEN 'CREATEROLE'  ELSE 'NOCREATEROLE'  END,
               CASE WHEN r.rolcreatedb    THEN 'CREATEDB'    ELSE 'NOCREATEDB'    END,
               CASE WHEN r.rolcanlogin    THEN 'LOGIN'       ELSE 'NOLOGIN'       END,
               CASE WHEN r.rolreplication THEN 'REPLICATION' ELSE 'NOREPLICATION' END,
               CASE WHEN r.rolbypassrls   THEN 'BYPASSRLS'   ELSE 'NOBYPASSRLS'   END,
               r.rolconnlimit,
               CASE
                   WHEN r.rolvaliduntil IS NULL THEN ''
                   ELSE pg_catalog.format(' VALID UNTIL %L', r.rolvaliduntil)
               END
           ) AS ddl
    FROM selected_roles AS r

    UNION ALL

    SELECT 20, r.rolname,
           pg_catalog.format(
               'COMMENT ON ROLE %I IS %L;',
               r.rolname,
               pg_catalog.shobj_description(r.oid, 'pg_authid')
           )
    FROM selected_roles AS r
    WHERE pg_catalog.shobj_description(r.oid, 'pg_authid') IS NOT NULL

    UNION ALL

    SELECT 30, rs.rolname || ':' || rs.parameter_name,
           CASE
               WHEN rs.setdatabase = 0 THEN
                   pg_catalog.format(
                       'ALTER ROLE %I SET %I TO %L;',
                       rs.rolname,
                       rs.parameter_name,
                       rs.parameter_value
                   )
               ELSE
                   pg_catalog.format(
                       'ALTER ROLE %I IN DATABASE %I SET %I TO %L;',
                       rs.rolname,
                       rs.datname,
                       rs.parameter_name,
                       rs.parameter_value
                   )
           END
    FROM role_settings AS rs

    UNION ALL

    SELECT 40, mr.granted_role || '->' || mr.member_role,
           CASE
               WHEN pg_catalog.current_setting('server_version_num')::integer >= 160000 THEN
                   pg_catalog.format(
                       'GRANT %I TO %I WITH ADMIN %s, INHERIT %s, SET %s;',
                       mr.granted_role,
                       mr.member_role,
                       pg_catalog.upper(mr.admin_option::text),
                       pg_catalog.upper(mr.inherit_option::text),
                       pg_catalog.upper(mr.set_option::text)
                   )
               ELSE
                   pg_catalog.format(
                       'GRANT %I TO %I%s;',
                       mr.granted_role,
                       mr.member_role,
                       CASE WHEN mr.admin_option THEN ' WITH ADMIN OPTION' ELSE '' END
                   )
           END
    FROM membership_rows AS mr
    WHERE mr.parent_selected AND mr.member_selected

    UNION ALL

    SELECT 50, mr.granted_role || '->' || mr.member_role,
           pg_catalog.format(
               '-- REVIEW SYSTEM/EXCLUDED MEMBERSHIP: GRANT %I TO %I%s;',
               mr.granted_role,
               mr.member_role,
               CASE WHEN mr.admin_option THEN ' WITH ADMIN OPTION' ELSE '' END
           )
    FROM membership_rows AS mr
    WHERE NOT (mr.parent_selected AND mr.member_selected)
)
SELECT output.ddl
FROM (
    SELECT section_no, item_name, ddl
    FROM generated

    UNION ALL

    SELECT
        90,
        'password-reminder',
        '-- Passwords were not exported. Set required LOGIN-role passwords separately on host2.'
) AS output
ORDER BY output.section_no, output.item_name;

