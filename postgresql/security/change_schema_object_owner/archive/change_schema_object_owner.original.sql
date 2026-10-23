DO $$
DECLARE
    obj_record RECORD;
    alter_cmd TEXT;
    target_schema TEXT := 'empf_rpa';
    target_owner TEXT := 'empf_rpa';
BEGIN
    -- 修改所有表、视图、物化视图、序列、函数、存储过程
    FOR obj_record IN
        -- 表、视图、物化视图、序列
        SELECT 
            n.nspname AS schema_name,
            c.relname AS object_name,
            CASE c.relkind
                WHEN 'r' THEN 'TABLE'
                WHEN 'v' THEN 'VIEW'
                WHEN 'm' THEN 'MATERIALIZED VIEW'
                WHEN 'S' THEN 'SEQUENCE'
                WHEN 'p' THEN 'PARTITIONED TABLE'
            END AS obj_type
        FROM pg_class c
        JOIN pg_namespace n ON c.relnamespace = n.oid
        WHERE n.nspname = target_schema
          AND c.relkind IN ('r', 'v', 'm', 'S', 'p')
        
        UNION ALL
        
        -- 函数和存储过程
        SELECT 
            n.nspname,
            p.proname,
            CASE p.prokind
                WHEN 'p' THEN 'PROCEDURE'
                WHEN 'f' THEN 'FUNCTION'
            END
        FROM pg_proc p
        JOIN pg_namespace n ON p.pronamespace = n.oid
        WHERE n.nspname = target_schema
          AND p.prokind IN ('p', 'f')
    LOOP
        alter_cmd := 'ALTER '
            || obj_record.obj_type
            || ' '
            || quote_ident(obj_record.schema_name) || '.'
            || quote_ident(obj_record.object_name)
            || CASE 
                WHEN obj_record.obj_type IN ('FUNCTION', 'PROCEDURE') 
                THEN '(' || pg_get_function_identity_arguments(
                    (SELECT oid FROM pg_proc WHERE proname = obj_record.object_name 
                     AND pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = obj_record.schema_name) 
                     LIMIT 1)
                ) || ')' 
                ELSE '' 
            END
            || ' OWNER TO ' || quote_ident(target_owner) || ';';
        
        BEGIN
            EXECUTE alter_cmd;
            RAISE NOTICE '✓ %: %', obj_record.obj_type, obj_record.object_name;
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING '✗ %: % - Error: %', 
                obj_record.obj_type, obj_record.object_name, SQLERRM;
        END;
    END LOOP;
    
    RAISE NOTICE '✓ All objects in schema "%" have been updated to owner "%".', 
        target_schema, target_owner;
END $$;
