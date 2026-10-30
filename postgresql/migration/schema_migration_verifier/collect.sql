-- PostgreSQL schema migration verifier v1.0
-- Run in a dedicated psql session, NOT Query Tool; see README.md.
\set ON_ERROR_STOP on
\set ECHO none
\set QUIET on
\pset pager off
\encoding UTF8
\if :{?schemas}
\else
  \set schemas 'public'
\endif
\if :{?output_file}
\else
  \set output_file 'snapshot.csv'
\endif
\if :{?check_rows}
\else
  \set check_rows true
\endif
\if :{?check_data}
\else
  \set check_data false
\endif
\if :{?statement_timeout}
\else
  \set statement_timeout '0'
\endif

-- Truncate a previous result now. A failed run must not leave a stale snapshot.
\o :output_file
\o
BEGIN ISOLATION LEVEL REPEATABLE READ;
SET LOCAL search_path = pg_catalog;
SET LOCAL timezone = 'UTC';
SET LOCAL datestyle = 'ISO, YMD';
SET LOCAL intervalstyle = 'postgres';
SET LOCAL extra_float_digits = 3;
SET LOCAL bytea_output = 'hex';
SET LOCAL row_security = off;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = :'statement_timeout';

CREATE TEMP TABLE verify_config ON COMMIT DROP AS
SELECT :'check_rows'::boolean AS check_rows,
       :'check_data'::boolean AS check_data;
CREATE TEMP TABLE verify_schemas ON COMMIT DROP AS
SELECT DISTINCT btrim(x) AS schema_name
FROM unnest(string_to_array(:'schemas', ',')) AS x
WHERE btrim(x) <> '';

DO $validate$
BEGIN
  IF current_setting('server_version_num')::integer < 120000 THEN
    RAISE EXCEPTION 'PostgreSQL 12 or newer is required';
  END IF;
  IF NOT EXISTS (SELECT FROM pg_temp.verify_schemas) THEN
    RAISE EXCEPTION 'Schema list cannot be empty';
  END IF;
  IF EXISTS (SELECT FROM pg_temp.verify_schemas s
             LEFT JOIN pg_namespace n ON n.nspname = s.schema_name
             WHERE n.oid IS NULL) THEN
    RAISE EXCEPTION 'Requested schema is missing; check schemas and database';
  END IF;
  IF EXISTS (SELECT FROM pg_temp.verify_schemas
             WHERE schema_name LIKE 'pg\_%' ESCAPE '\'
                OR schema_name = 'information_schema') THEN
    RAISE EXCEPTION 'Only user schemas are supported';
  END IF;
END
$validate$;

CREATE TEMP TABLE verify_records (
  record_type text NOT NULL,
  schema_name text NOT NULL,
  object_type text NOT NULL,
  object_name text NOT NULL,
  signature text NOT NULL DEFAULT '',
  details jsonb NOT NULL,
  PRIMARY KEY (record_type, schema_name, object_type, object_name, signature)
) ON COMMIT DROP;

CREATE TEMP VIEW verify_relations AS
SELECT c.*, n.nspname AS schema_name
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_temp.verify_schemas s ON s.schema_name = n.nspname
WHERE c.relkind IN ('r','p','f','v','m','S','i','I','c');

INSERT INTO pg_temp.verify_records
SELECT 'META','','RUN','','', jsonb_build_object(
  'format_version',1,'collector_version','1.0',
  'database',current_database(),'server_address',inet_server_addr(),
  'server_port',inet_server_port(),'server_version',current_setting('server_version'),
  'server_version_num',current_setting('server_version_num')::integer,
  'database_encoding',current_setting('server_encoding'),
  'database_collation',(SELECT datcollate FROM pg_database WHERE datname=current_database()),
  'database_ctype',(SELECT datctype FROM pg_database WHERE datname=current_database()),
  'collected_at',transaction_timestamp(),'collected_by',current_user,
  'schemas',(SELECT jsonb_agg(schema_name ORDER BY schema_name) FROM pg_temp.verify_schemas),
  'check_rows',cfg.check_rows,'check_data',cfg.check_data)
FROM pg_temp.verify_config cfg;

INSERT INTO pg_temp.verify_records
SELECT 'STRUCTURE',s.schema_name,'SCHEMA',s.schema_name,'','{}'::jsonb
FROM pg_temp.verify_schemas s;

-- Physical OIDs, sizes, statistics, filenodes and dropped-column slots are excluded.
INSERT INTO pg_temp.verify_records
SELECT 'STRUCTURE',c.schema_name,
  CASE c.relkind WHEN 'r' THEN 'TABLE' WHEN 'p' THEN 'PARTITIONED_TABLE'
    WHEN 'f' THEN 'FOREIGN_TABLE' WHEN 'v' THEN 'VIEW'
    WHEN 'm' THEN 'MATERIALIZED_VIEW' WHEN 'S' THEN 'SEQUENCE'
    WHEN 'i' THEN 'INDEX' WHEN 'I' THEN 'PARTITIONED_INDEX'
    WHEN 'c' THEN 'COMPOSITE_TYPE' END,
  c.relname,'',jsonb_build_object(
    'persistence',c.relpersistence,'is_partition',c.relispartition,
    'options',(SELECT jsonb_agg(v ORDER BY v) FROM unnest(c.reloptions) AS v),
    'partition_key',CASE WHEN c.relkind='p' THEN pg_get_partkeydef(c.oid) END,
    'partition_bound',pg_get_expr(c.relpartbound,c.oid,false),
    'parents',(SELECT jsonb_agg(format('%I.%I',pn.nspname,pc.relname) ORDER BY i.inhseqno)
       FROM pg_inherits i JOIN pg_class pc ON pc.oid=i.inhparent
       JOIN pg_namespace pn ON pn.oid=pc.relnamespace WHERE i.inhrelid=c.oid),
    'definition',CASE WHEN c.relkind IN ('v','m') THEN pg_get_viewdef(c.oid,false)
                      WHEN c.relkind IN ('i','I') THEN pg_get_indexdef(c.oid) END,
    'row_security',c.relrowsecurity,'force_row_security',c.relforcerowsecurity,
    'replica_identity',c.relreplident)
FROM pg_temp.verify_relations c;

INSERT INTO pg_temp.verify_records
SELECT 'STRUCTURE',c.schema_name,'COLUMN',c.relname,a.attname,
  jsonb_build_object(
    'position',row_number() OVER (PARTITION BY c.oid ORDER BY a.attnum),
    'type',format_type(a.atttypid,a.atttypmod),'not_null',a.attnotnull,
    'identity',a.attidentity,'generated',a.attgenerated,
    'default',pg_get_expr(d.adbin,d.adrelid,false),
    'collation',CASE WHEN a.attcollation<>0 THEN format('%I.%I',cn.nspname,co.collname) END)
FROM pg_temp.verify_relations c JOIN pg_attribute a ON a.attrelid=c.oid
LEFT JOIN pg_attrdef d ON d.adrelid=a.attrelid AND d.adnum=a.attnum
LEFT JOIN pg_collation co ON co.oid=a.attcollation
LEFT JOIN pg_namespace cn ON cn.oid=co.collnamespace
WHERE c.relkind IN ('r','p','f','v','m','c') AND a.attnum>0 AND NOT a.attisdropped;

-- NOT NULL is compared through COLUMN, avoiding PG17/PG18 catalog differences.
INSERT INTO pg_temp.verify_records
SELECT 'STRUCTURE',c.schema_name,'CONSTRAINT',c.relname,con.conname,
  jsonb_build_object('type',con.contype,'definition',pg_get_constraintdef(con.oid,false),
    'validated',con.convalidated,'deferrable',con.condeferrable,
    'initially_deferred',con.condeferred,'local',con.conislocal,
    'inherit_count',con.coninhcount)
FROM pg_constraint con JOIN pg_temp.verify_relations c ON c.oid=con.conrelid
WHERE con.contype<>'n';

INSERT INTO pg_temp.verify_records
SELECT 'STRUCTURE',c.schema_name,'SEQUENCE_DEFINITION',c.relname,'',
  jsonb_build_object('type',format_type(q.seqtypid,NULL),'start',q.seqstart,
    'increment',q.seqincrement,'min',q.seqmin,'max',q.seqmax,
    'cache',q.seqcache,'cycle',q.seqcycle,
    'owned_by',(SELECT jsonb_agg(format('%I.%I.%I',tn.nspname,t.relname,a.attname)
                  ORDER BY tn.nspname,t.relname,a.attname)
       FROM pg_depend d JOIN pg_class t ON t.oid=d.refobjid
       JOIN pg_namespace tn ON tn.oid=t.relnamespace
       JOIN pg_attribute a ON a.attrelid=t.oid AND a.attnum=d.refobjsubid
       WHERE d.classid='pg_class'::regclass AND d.objid=c.oid
         AND d.refclassid='pg_class'::regclass AND d.deptype IN ('a','i')))
FROM pg_temp.verify_relations c JOIN pg_sequence q ON q.seqrelid=c.oid;

INSERT INTO pg_temp.verify_records
SELECT 'STRUCTURE',n.nspname,
  CASE p.prokind WHEN 'p' THEN 'PROCEDURE' WHEN 'a' THEN 'AGGREGATE'
    WHEN 'w' THEN 'WINDOW_FUNCTION' ELSE 'FUNCTION' END,
  p.proname,pg_get_function_identity_arguments(p.oid),
  CASE WHEN p.prokind<>'a' THEN jsonb_build_object('definition',pg_get_functiondef(p.oid))
  ELSE jsonb_build_object('arguments',pg_get_function_arguments(p.oid),
    'result',pg_get_function_result(p.oid),'kind',ag.aggkind,
    'direct_arguments',ag.aggnumdirectargs,
    'transition',ag.aggtransfn::regprocedure::text,
    'final',ag.aggfinalfn::regprocedure::text,
    'combine',ag.aggcombinefn::regprocedure::text,
    'serial',ag.aggserialfn::regprocedure::text,
    'deserial',ag.aggdeserialfn::regprocedure::text,
    'state_type',ag.aggtranstype::regtype::text,
    'initial',ag.agginitval) END
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
JOIN pg_temp.verify_schemas s ON s.schema_name=n.nspname
LEFT JOIN pg_aggregate ag ON ag.aggfnoid=p.oid;

INSERT INTO pg_temp.verify_records
SELECT 'STRUCTURE',c.schema_name,'TRIGGER',c.relname,t.tgname,
  jsonb_build_object('definition',pg_get_triggerdef(t.oid,false),'enabled',t.tgenabled)
FROM pg_trigger t JOIN pg_temp.verify_relations c ON c.oid=t.tgrelid
WHERE NOT t.tgisinternal;

INSERT INTO pg_temp.verify_records
SELECT 'STRUCTURE',c.schema_name,'RULE',c.relname,r.rulename,
  jsonb_build_object('definition',pg_get_ruledef(r.oid,false),'enabled',r.ev_enabled)
FROM pg_rewrite r JOIN pg_temp.verify_relations c ON c.oid=r.ev_class
WHERE r.rulename<>'_RETURN';

INSERT INTO pg_temp.verify_records
SELECT 'STRUCTURE',c.schema_name,'POLICY',c.relname,p.polname,
  jsonb_build_object('command',p.polcmd,'permissive',p.polpermissive,
    'roles',(SELECT jsonb_agg(CASE WHEN x=0 THEN 'PUBLIC' ELSE pg_get_userbyid(x) END
                      ORDER BY CASE WHEN x=0 THEN 'PUBLIC' ELSE pg_get_userbyid(x) END)
             FROM unnest(p.polroles) AS x),
    'using',pg_get_expr(p.polqual,p.polrelid,false),
    'with_check',pg_get_expr(p.polwithcheck,p.polrelid,false))
FROM pg_policy p JOIN pg_temp.verify_relations c ON c.oid=p.polrelid;

INSERT INTO pg_temp.verify_records
SELECT 'STRUCTURE',n.nspname,CASE t.typtype WHEN 'e' THEN 'ENUM' ELSE 'DOMAIN' END,
  t.typname,'',jsonb_build_object(
    'base_type',CASE WHEN t.typtype='d' THEN format_type(t.typbasetype,t.typtypmod) END,
    'not_null',t.typnotnull,'default',t.typdefault,
    'labels',(SELECT jsonb_agg(e.enumlabel ORDER BY e.enumsortorder) FROM pg_enum e WHERE e.enumtypid=t.oid),
    'constraints',(SELECT jsonb_agg(jsonb_build_object('name',q.conname,
         'definition',pg_get_constraintdef(q.oid,false),'validated',q.convalidated) ORDER BY q.conname)
         FROM pg_constraint q WHERE q.contypid=t.oid AND q.contype<>'n'))
FROM pg_type t JOIN pg_namespace n ON n.oid=t.typnamespace
JOIN pg_temp.verify_schemas s ON s.schema_name=n.nspname
WHERE t.typtype IN ('e','d');

INSERT INTO pg_temp.verify_records
SELECT 'STRUCTURE',c.schema_name,'FOREIGN_TABLE_OPTIONS',c.relname,'',
  jsonb_build_object('server',fs.srvname,'wrapper',fdw.fdwname,
    'options',(SELECT jsonb_agg(x ORDER BY x) FROM unnest(ft.ftoptions) x))
FROM pg_foreign_table ft JOIN pg_temp.verify_relations c ON c.oid=ft.ftrelid
JOIN pg_foreign_server fs ON fs.oid=ft.ftserver
JOIN pg_foreign_data_wrapper fdw ON fdw.oid=fs.srvfdw;

-- Normalize ACLs by role names, never role OIDs. Security differences are REVIEW.
CREATE FUNCTION pg_temp.verify_acl(a aclitem[]) RETURNS jsonb LANGUAGE sql STABLE AS $acl$
  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'grantor',pg_get_userbyid(x.grantor),
    'grantee',CASE WHEN x.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(x.grantee) END,
    'privilege',x.privilege_type,'grantable',x.is_grantable)
    ORDER BY pg_get_userbyid(x.grantor),
      CASE WHEN x.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(x.grantee) END,
      x.privilege_type,x.is_grantable),'[]'::jsonb)
  FROM aclexplode(a) x
$acl$;

INSERT INTO pg_temp.verify_records
SELECT 'SECURITY',c.schema_name,'RELATION',c.relname,'',
  jsonb_build_object('owner',pg_get_userbyid(c.relowner),
    'acl',pg_temp.verify_acl(coalesce(c.relacl,
      acldefault(CASE WHEN c.relkind='S' THEN 'S'::"char" ELSE 'r'::"char" END,c.relowner))))
FROM pg_temp.verify_relations c WHERE c.relkind IN ('r','p','f','v','m','S')
UNION ALL
SELECT 'SECURITY',n.nspname,'SCHEMA',n.nspname,'',
  jsonb_build_object('owner',pg_get_userbyid(n.nspowner),
    'acl',pg_temp.verify_acl(coalesce(n.nspacl,acldefault('n',n.nspowner))))
FROM pg_namespace n JOIN pg_temp.verify_schemas s ON s.schema_name=n.nspname
UNION ALL
SELECT 'SECURITY',n.nspname,'ROUTINE',p.proname,pg_get_function_identity_arguments(p.oid),
  jsonb_build_object('owner',pg_get_userbyid(p.proowner),
    'acl',pg_temp.verify_acl(coalesce(p.proacl,acldefault('f',p.proowner))))
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
JOIN pg_temp.verify_schemas s ON s.schema_name=n.nspname
UNION ALL
SELECT 'SECURITY',c.schema_name,'COLUMN',c.relname,a.attname,
  jsonb_build_object('acl',pg_temp.verify_acl(a.attacl))
FROM pg_attribute a JOIN pg_temp.verify_relations c ON c.oid=a.attrelid
WHERE a.attnum>0 AND NOT a.attisdropped AND a.attacl IS NOT NULL;

INSERT INTO pg_temp.verify_records
SELECT 'SECURITY',coalesce(n.nspname,''),'DEFAULT_PRIVILEGES',
  pg_get_userbyid(d.defaclrole),d.defaclobjtype::text,
  jsonb_build_object('acl',pg_temp.verify_acl(d.defaclacl))
FROM pg_default_acl d LEFT JOIN pg_namespace n ON n.oid=d.defaclnamespace
WHERE d.defaclnamespace=0 OR n.nspname IN (SELECT schema_name FROM pg_temp.verify_schemas);

INSERT INTO pg_temp.verify_records
SELECT 'ENVIRONMENT','','EXTENSION',e.extname,'',
  jsonb_build_object('version',e.extversion,'schema',n.nspname)
FROM pg_extension e JOIN pg_namespace n ON n.oid=e.extnamespace;

INSERT INTO pg_temp.verify_records
SELECT 'HEALTH',c.schema_name,'INDEX',c.relname,'',
  jsonb_build_object('status','REVIEW','valid',i.indisvalid,
                    'ready',i.indisready,'live',i.indislive)
FROM pg_index i JOIN pg_temp.verify_relations c ON c.oid=i.indexrelid
WHERE NOT i.indisvalid OR NOT i.indisready OR NOT i.indislive
UNION ALL
SELECT 'HEALTH',c.schema_name,'CONSTRAINT',c.relname,con.conname,
  jsonb_build_object('status','REVIEW','validated',false)
FROM pg_constraint con JOIN pg_temp.verify_relations c ON c.oid=con.conrelid
WHERE NOT con.convalidated AND con.contype<>'n';

INSERT INTO pg_temp.verify_records
SELECT 'STATE',c.schema_name,'MATERIALIZED_VIEW',c.relname,'',
  jsonb_build_object('populated',c.relispopulated)
FROM pg_temp.verify_relations c WHERE c.relkind='m';

-- Counts use ONLY, include local leaf partitions and storage in inheritance parents.
-- RLS is disabled in error-on-filter mode. Permission errors are never zero counts.
DO $data$
DECLARE r record; cfg record; n bigint; h1 numeric; h2 numeric;
BEGIN
  SELECT * INTO cfg FROM pg_temp.verify_config;
  IF cfg.check_rows OR cfg.check_data THEN
    FOR r IN SELECT * FROM pg_temp.verify_relations WHERE relkind='r' ORDER BY schema_name,relname LOOP
      BEGIN
        RAISE NOTICE 'Checking %.%',r.schema_name,r.relname;
        IF cfg.check_data THEN
          EXECUTE format(
            'SELECT count(*),coalesce(sum((''x''||substr(h,1,16))::bit(64)::bigint::numeric),0),
                            coalesce(sum((''x''||substr(h,17,16))::bit(64)::bigint::numeric),0)
             FROM (SELECT md5(to_jsonb(t)::text) AS h FROM ONLY %I.%I t) q',r.schema_name,r.relname)
          INTO n,h1,h2;
        ELSE
          EXECUTE format('SELECT count(*) FROM ONLY %I.%I',r.schema_name,r.relname) INTO n;
        END IF;
        INSERT INTO pg_temp.verify_records VALUES
          ('DATA',r.schema_name,'TABLE',r.relname,'',
           jsonb_build_object('status','OK','row_count',n,'hash_sum_1',h1,'hash_sum_2',h2));
      EXCEPTION WHEN OTHERS THEN
        INSERT INTO pg_temp.verify_records VALUES
          ('DATA',r.schema_name,'TABLE',r.relname,'',
           jsonb_build_object('status','ERROR','sqlstate',SQLSTATE,'message',SQLERRM));
      END;
    END LOOP;
  END IF;
END
$data$;

-- Sequence reads do not invoke nextval/setval; state is NOT covered by MVCC.
DO $seq$
DECLARE r record; v bigint; called boolean;
BEGIN
  FOR r IN SELECT * FROM pg_temp.verify_relations WHERE relkind='S' ORDER BY schema_name,relname LOOP
    BEGIN
      EXECUTE format('SELECT last_value,is_called FROM %I.%I',r.schema_name,r.relname) INTO v,called;
      INSERT INTO pg_temp.verify_records VALUES
        ('STATE',r.schema_name,'SEQUENCE',r.relname,'',
         jsonb_build_object('status','OK','last_value',v,'is_called',called));
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO pg_temp.verify_records VALUES
        ('STATE',r.schema_name,'SEQUENCE',r.relname,'',
         jsonb_build_object('status','ERROR','sqlstate',SQLSTATE,'message',SQLERRM));
    END;
  END LOOP;
END
$seq$;

-- Trailer detects truncated/incomplete CSV imports, including interrupted collection.
INSERT INTO pg_temp.verify_records
SELECT 'ZZ_END','','COMPLETE','','',jsonb_build_object('record_count',count(*))
FROM pg_temp.verify_records;
\o :output_file
COPY (SELECT * FROM pg_temp.verify_records
      ORDER BY record_type COLLATE "C",schema_name COLLATE "C",
               object_type COLLATE "C",object_name COLLATE "C",signature COLLATE "C")
TO STDOUT WITH (FORMAT csv,HEADER true);
\o
SELECT count(*) FILTER (WHERE record_type='STRUCTURE') AS structure_records,
       count(*) FILTER (WHERE record_type='DATA') AS data_tables,
       count(*) FILTER (WHERE details->>'status'='ERROR') AS collection_errors
FROM pg_temp.verify_records;
ROLLBACK;
\echo 'Collection finished. Snapshot:' :output_file
