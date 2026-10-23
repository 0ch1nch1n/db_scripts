/*
PostgreSQL 11+：统一指定 schema 中常见对象的 owner。
默认仅预览；确认目标数据库、schema、角色和输出后，才将 v_execute 改为 true。
范围：普通表、分区表、外部表、视图、物化视图、序列、普通函数、存储过程。
不修改 schema 本身；跳过扩展成员。详细边界见同目录 README.md。
执行模式是单个事务：任何未处理错误都会回滚本 DO 块的全部更改。
运行期间不要并发执行对象创建、删除、重命名或 owner 变更。
*/
DO $owner_change$
DECLARE
    v_target_schema TEXT := 'empf_rpa';
    v_target_owner TEXT := 'empf_rpa';
    v_execute BOOLEAN := false;

    v_schema_oid OID;
    v_owner_oid OID;
    v_current_owner OID;
    v_owned_table_in_scope BOOLEAN;
    v_command TEXT;
    obj RECORD;

    v_ready INTEGER := 0;
    v_changed INTEGER := 0;
    v_already INTEGER := 0;
    v_extension INTEGER := 0;
    v_indirect INTEGER := 0;
    v_blocked INTEGER := 0;
BEGIN
    IF pg_catalog.current_setting('server_version_num')::INTEGER < 110000 THEN
        RAISE EXCEPTION '需要 PostgreSQL 11 或更新版本（使用 pg_proc.prokind）。';
    END IF;

    SELECT n.oid INTO v_schema_oid
    FROM pg_catalog.pg_namespace AS n WHERE n.nspname = v_target_schema;
    IF v_schema_oid IS NULL THEN
        RAISE EXCEPTION 'Schema 不存在：%', v_target_schema;
    END IF;
    IF pg_catalog.left(v_target_schema, 3) = 'pg_' OR v_target_schema = 'information_schema' THEN
        RAISE EXCEPTION '本脚本不处理系统或临时 schema：%', v_target_schema;
    END IF;

    SELECT r.oid INTO v_owner_oid
    FROM pg_catalog.pg_roles AS r WHERE r.rolname = v_target_owner;
    IF v_owner_oid IS NULL THEN
        RAISE EXCEPTION '目标角色不存在：%', v_target_owner;
    END IF;

    RAISE NOTICE 'database=%, schema=%, owner=%, execute=%',
        pg_catalog.current_database(), v_target_schema, v_target_owner, v_execute;

    FOR obj IN
        SELECT c.oid AS object_oid,
               'pg_catalog.pg_class'::pg_catalog.regclass AS catalog_oid,
               n.nspname AS schema_name, c.relname AS object_name,
               CASE c.relkind
                   WHEN 'r' THEN 'TABLE'
                   WHEN 'p' THEN 'TABLE'
                   WHEN 'f' THEN 'FOREIGN TABLE'
                   WHEN 'v' THEN 'VIEW'
                   WHEN 'm' THEN 'MATERIALIZED VIEW'
                   WHEN 'S' THEN 'SEQUENCE'
               END AS object_type,
               NULL::TEXT AS identity_arguments,
               CASE WHEN c.relkind IN ('r', 'p', 'f') THEN 10
                    WHEN c.relkind = 'S' THEN 30 ELSE 20 END AS sort_order,
               seq_dep.refobjid AS owned_table_oid,
               EXISTS (
                   SELECT 1 FROM pg_catalog.pg_depend AS e
                   WHERE e.classid = 'pg_catalog.pg_class'::pg_catalog.regclass
                     AND e.objid = c.oid AND e.deptype = 'e'
               ) AS extension_member
        FROM pg_catalog.pg_class AS c
        JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
        LEFT JOIN pg_catalog.pg_depend AS seq_dep
          ON c.relkind = 'S'
         AND seq_dep.classid = 'pg_catalog.pg_class'::pg_catalog.regclass
         AND seq_dep.objid = c.oid AND seq_dep.objsubid = 0
         AND seq_dep.refclassid = 'pg_catalog.pg_class'::pg_catalog.regclass
         AND seq_dep.refobjsubid > 0 AND seq_dep.deptype IN ('a', 'i')
        WHERE n.oid = v_schema_oid AND c.relkind IN ('r', 'p', 'f', 'v', 'm', 'S')

        UNION ALL

        SELECT p.oid, 'pg_catalog.pg_proc'::pg_catalog.regclass,
               n.nspname, p.proname,
               CASE p.prokind WHEN 'p' THEN 'PROCEDURE' ELSE 'FUNCTION' END,
               pg_catalog.pg_get_function_identity_arguments(p.oid),
               40, NULL::OID,
               EXISTS (
                   SELECT 1 FROM pg_catalog.pg_depend AS e
                   WHERE e.classid = 'pg_catalog.pg_proc'::pg_catalog.regclass
                     AND e.objid = p.oid AND e.deptype = 'e'
               )
        FROM pg_catalog.pg_proc AS p
        JOIN pg_catalog.pg_namespace AS n ON n.oid = p.pronamespace
        WHERE n.oid = v_schema_oid AND p.prokind IN ('f', 'p')
        ORDER BY sort_order, schema_name, object_name, identity_arguments, object_oid
    LOOP
        IF obj.extension_member THEN
            v_extension := v_extension + 1;
            RAISE NOTICE '[SKIP EXTENSION] % %.% (oid=%)',
                obj.object_type, obj.schema_name, obj.object_name, obj.object_oid;
            CONTINUE;
        END IF;

        -- 表变更会自动处理其关联序列，因此每轮重新读取 owner，不能沿用游标快照。
        IF obj.catalog_oid = 'pg_catalog.pg_class'::pg_catalog.regclass THEN
            SELECT c.relowner INTO v_current_owner
            FROM pg_catalog.pg_class AS c WHERE c.oid = obj.object_oid;
        ELSE
            SELECT p.proowner INTO v_current_owner
            FROM pg_catalog.pg_proc AS p WHERE p.oid = obj.object_oid;
        END IF;
        IF v_current_owner IS NULL THEN
            RAISE EXCEPTION '对象已消失，请停止并发 DDL 后重新运行：%.% (oid=%)',
                obj.schema_name, obj.object_name, obj.object_oid;
        END IF;
        IF v_current_owner = v_owner_oid THEN
            v_already := v_already + 1;
            CONTINUE;
        END IF;

        -- SERIAL / IDENTITY 序列应随所属表迁移，不直接 ALTER SEQUENCE OWNER。
        IF obj.object_type = 'SEQUENCE' AND obj.owned_table_oid IS NOT NULL THEN
            SELECT EXISTS (
                SELECT 1 FROM pg_catalog.pg_class AS t
                WHERE t.oid = obj.owned_table_oid AND t.relnamespace = v_schema_oid
                  AND t.relkind IN ('r', 'p', 'f')
                  AND NOT EXISTS (
                      SELECT 1 FROM pg_catalog.pg_depend AS e
                      WHERE e.classid = 'pg_catalog.pg_class'::pg_catalog.regclass
                        AND e.objid = t.oid AND e.deptype = 'e'
                  )
            ) INTO v_owned_table_in_scope;

            IF NOT v_execute AND v_owned_table_in_scope THEN
                v_indirect := v_indirect + 1;
                RAISE NOTICE '[INDIRECT] SEQUENCE %.% 将随所属表迁移（table oid=%）。',
                    obj.schema_name, obj.object_name, obj.owned_table_oid;
                CONTINUE;
            END IF;
            v_blocked := v_blocked + 1;
            IF v_execute THEN
                RAISE EXCEPTION '依附序列 %.% 的 owner 未随所属表迁移（table oid=%）；本次更改回滚，请检查跨 schema 或扩展依赖。',
                    obj.schema_name, obj.object_name, obj.owned_table_oid;
            ELSE
                RAISE WARNING '[BLOCKED] SEQUENCE %.% 的所属表不在处理范围（table oid=%）；执行模式会报错回滚。',
                    obj.schema_name, obj.object_name, obj.owned_table_oid;
                CONTINUE;
            END IF;
        END IF;

        IF obj.object_type IN ('FUNCTION', 'PROCEDURE') THEN
            v_command := pg_catalog.format('ALTER %s %I.%I(%s) OWNER TO %I;',
                obj.object_type, obj.schema_name, obj.object_name,
                obj.identity_arguments, v_target_owner);
        ELSE
            v_command := pg_catalog.format('ALTER %s %s%I.%I OWNER TO %I;',
                obj.object_type,
                CASE WHEN obj.object_type = 'TABLE' THEN 'ONLY ' ELSE '' END,
                obj.schema_name, obj.object_name, v_target_owner);
        END IF;
        v_ready := v_ready + 1;
        IF v_execute THEN
            RAISE NOTICE '[EXECUTE] %', v_command;
            EXECUTE v_command;
            IF obj.catalog_oid = 'pg_catalog.pg_class'::pg_catalog.regclass THEN
                SELECT c.relowner INTO v_current_owner
                FROM pg_catalog.pg_class AS c WHERE c.oid = obj.object_oid;
            ELSE
                SELECT p.proowner INTO v_current_owner
                FROM pg_catalog.pg_proc AS p WHERE p.oid = obj.object_oid;
            END IF;
            IF v_current_owner IS DISTINCT FROM v_owner_oid THEN
                RAISE EXCEPTION 'Owner 校验失败：%.% (oid=%)',
                    obj.schema_name, obj.object_name, obj.object_oid;
            END IF;
            v_changed := v_changed + 1;
        ELSE
            RAISE NOTICE '[PREVIEW] %', v_command;
        END IF;
    END LOOP;

    RAISE NOTICE '结束：execute=%, direct_commands=%, changed=%, already_target=%, extension_skipped=%, indirect_preview=%, blocked=%',
        v_execute, v_ready, v_changed, v_already, v_extension, v_indirect, v_blocked;
END;
$owner_change$;
