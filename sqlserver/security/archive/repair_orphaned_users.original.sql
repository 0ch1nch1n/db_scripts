USE master;
GO

SET NOCOUNT ON;

-- 0 = 仅预览，1 = 自动执行修复
DECLARE @Execute BIT = 0;

DECLARE @DB SYSNAME;
DECLARE @SQL NVARCHAR(MAX);
DECLARE @FixSQL NVARCHAR(MAX);
DECLARE @ID INT;

-- 保存待修复用户
CREATE TABLE #FixUsers
(
    ID INT IDENTITY(1,1) PRIMARY KEY,
    DatabaseName SYSNAME,
    DatabaseUser SYSNAME,
    LoginName SYSNAME,
    FixSQL NVARCHAR(MAX),
    Status NVARCHAR(20) DEFAULT N'PENDING',
    ErrorMessage NVARCHAR(4000)
);

-- 保存数据库扫描错误
CREATE TABLE #ScanErrors
(
    DatabaseName SYSNAME,
    ErrorMessage NVARCHAR(4000)
);

-- 遍历所有 ONLINE、可写的用户数据库
DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name
FROM sys.databases
WHERE database_id > 4
  AND state_desc = 'ONLINE'
  AND is_read_only = 0
  AND name <> N'distribution'
  AND HAS_DBACCESS(name) = 1
ORDER BY name;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DB;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @SQL = N'
    USE ' + QUOTENAME(@DB) + N';

    INSERT INTO #FixUsers
    (
        DatabaseName,
        DatabaseUser,
        LoginName,
        FixSQL
    )
    SELECT
        DB_NAME(),
        dp.name,
        sl.name,
        N''ALTER USER ''
        + (QUOTENAME(dp.name) COLLATE DATABASE_DEFAULT)
        + N'' WITH LOGIN = ''
        + (QUOTENAME(sl.name) COLLATE DATABASE_DEFAULT)
        + N'';''
    FROM sys.database_principals dp
    INNER JOIN sys.sql_logins sl
        ON dp.name COLLATE DATABASE_DEFAULT
         = sl.name COLLATE DATABASE_DEFAULT
    WHERE dp.type = ''S''
      AND dp.authentication_type_desc = ''INSTANCE''
      AND dp.principal_id > 4

      -- 排除已经存在 SID 映射的用户
      AND NOT EXISTS (
          SELECT 1
          FROM sys.server_principals sp
          WHERE sp.sid = dp.sid
      )

      -- 排除 Login 已映射其他用户的情况
      AND NOT EXISTS (
          SELECT 1
          FROM sys.database_principals dp2
          WHERE dp2.sid = sl.sid
            AND dp2.principal_id <> dp.principal_id
      );
    ';

    BEGIN TRY
        EXEC sys.sp_executesql @SQL;
    END TRY
    BEGIN CATCH
        INSERT INTO #ScanErrors
        VALUES (@DB, ERROR_MESSAGE());
    END CATCH;

    FETCH NEXT FROM db_cursor INTO @DB;
END;

CLOSE db_cursor;
DEALLOCATE db_cursor;

-- 自动执行修复
IF @Execute = 1
BEGIN
    DECLARE fix_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT ID, DatabaseName, FixSQL
    FROM #FixUsers
    ORDER BY ID;

    OPEN fix_cursor;
    FETCH NEXT FROM fix_cursor INTO @ID, @DB, @FixSQL;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @SQL =
                N'USE ' + QUOTENAME(@DB)
                + N'; '
                + @FixSQL;

            EXEC sys.sp_executesql @SQL;

            UPDATE #FixUsers
            SET Status = N'SUCCESS'
            WHERE ID = @ID;
        END TRY
        BEGIN CATCH
            UPDATE #FixUsers
            SET
                Status = N'FAILED',
                ErrorMessage = ERROR_MESSAGE()
            WHERE ID = @ID;
        END CATCH;

        FETCH NEXT FROM fix_cursor
        INTO @ID, @DB, @FixSQL;
    END;

    CLOSE fix_cursor;
    DEALLOCATE fix_cursor;
END;

-- 输出修复结果
SELECT
    DatabaseName,
    DatabaseUser,
    LoginName,
    FixSQL,
    Status,
    ErrorMessage
FROM #FixUsers
ORDER BY DatabaseName, DatabaseUser;

-- 汇总统计
SELECT
    Status,
    COUNT(*) AS UserCount
FROM #FixUsers
GROUP BY Status;

-- 扫描失败的数据库
SELECT *
FROM #ScanErrors;

DROP TABLE #FixUsers;
DROP TABLE #ScanErrors;
