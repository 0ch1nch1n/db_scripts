-- 00_context.csv
SELECT current_database() AS database_name,
        current_user AS database_user, GETDATE() AS server_time,
        version() AS engine_version, u.usesuper AS is_superuser
        FROM pg_user u WHERE u.usename = current_user;

-- 10_roles.csv
SELECT * FROM svv_roles ORDER BY role_name;

-- 11_users.csv
SELECT usesysid AS user_id, usename AS user_name,
        usesuper AS is_superuser, usecreatedb AS can_create_database
        FROM pg_user ORDER BY usename;

-- 20_user_role_grants.csv
SELECT * FROM svv_user_grants ORDER BY user_name, role_name;

-- 21_role_role_grants.csv
SELECT * FROM svv_role_grants ORDER BY role_name, granted_role_name;

-- 30_system_privileges.csv
SELECT * FROM svv_system_privileges;

-- 31_database_privileges.csv
SELECT * FROM svv_database_privileges;

-- 32_schema_privileges.csv
SELECT * FROM svv_schema_privileges;

-- 33_relation_privileges.csv
SELECT * FROM svv_relation_privileges;

-- 34_column_privileges.csv
SELECT * FROM svv_column_privileges;

-- 35_function_privileges.csv
SELECT * FROM svv_function_privileges;

-- 36_default_privileges.csv
SELECT * FROM svv_default_privileges;

-- 37_iam_privileges.csv
SELECT * FROM svv_iam_privileges;

-- 38_language_privileges.csv
SELECT * FROM svv_language_privileges;

-- 39_datashare_privileges.csv
SELECT * FROM svv_datashare_privileges;

-- 40_ml_model_privileges.csv
SELECT * FROM svv_ml_model_privileges;
