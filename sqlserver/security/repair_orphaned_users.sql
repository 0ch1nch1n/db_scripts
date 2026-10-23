/*
批量检查并修复 SQL Server 实例中的孤立 SQL 用户。
适用：SQL Server 2012+；以 sysadmin 连接，在 SSMS / Azure Data Studio / sqlcmd 中执行。
默认仅预览。仅自动处理名称完全一致、Login 启用且未被其他用户占用的 SQL Login。
同名不代表同一身份：将 @Execute 改为 1 前，必须人工确认映射意图。
不创建 Login，不处理 Windows / contained 用户，不启用禁用的 Login。
不要与数据库还原、切换、用户或 Login 的并发 DDL 同时执行。
*/
USE master;
GO
SET NOCOUNT ON;

-- 0 = 仅预览；1 = 重新扫描并执行符合条件的映射
DECLARE @Execute BIT = 0;

-- 完整元数据可见性和跨库 ALTER USER 权限是批量判断的前提。
IF ISNULL(IS_SRVROLEMEMBER(N'sysadmin'), 0) <> 1
    THROW 51000, N'请使用 sysadmin 连接运行，以免元数据不可见导致孤立用户误判。', 1;

-- 每个用户使用独立事务，不允许嵌入调用方事务。
IF @@TRANCOUNT <> 0 OR (@@OPTIONS & 2) = 2
    THROW 51001, N'请在无活动事务且 IMPLICIT_TRANSACTIONS OFF 的连接中运行。', 1;

IF OBJECT_ID(N'tempdb..#OrphanRepairUsers') IS NOT NULL
    DROP TABLE #OrphanRepairUsers;
IF OBJECT_ID(N'tempdb..#OrphanRepairDatabases') IS NOT NULL
    DROP TABLE #OrphanRepairDatabases;

CREATE TABLE #OrphanRepairDatabases
(
    DatabaseId INT NOT NULL PRIMARY KEY,
    DatabaseName SYSNAME COLLATE DATABASE_DEFAULT NOT NULL,
    DatabaseCreateDate DATETIME NOT NULL,
    Status NVARCHAR(20) NOT NULL,
    ErrorNumber INT NULL,
    Detail NVARCHAR(4000) NULL
);

CREATE TABLE #OrphanRepairUsers
(
    ID INT IDENTITY(1,1) PRIMARY KEY,
    DatabaseId INT NOT NULL,
    DatabaseName SYSNAME COLLATE DATABASE_DEFAULT NOT NULL,
    DatabaseUser SYSNAME COLLATE DATABASE_DEFAULT NOT NULL,
    UserPrincipalId INT NOT NULL,
    OriginalUserSID VARBINARY(85) NOT NULL,
    LoginName SYSNAME COLLATE DATABASE_DEFAULT NULL,
    LoginSID VARBINARY(85) NULL,
    FixSQL NVARCHAR(MAX) NULL,
    Status NVARCHAR(32) NOT NULL,
    ErrorNumber INT NULL,
    Detail NVARCHAR(4000) NULL
);

-- 记录所有用户库，包括跳过原因。数据库列表为本次运行开始时的快照。
INSERT INTO #OrphanRepairDatabases
    (DatabaseId, DatabaseName, DatabaseCreateDate, Status, Detail)
SELECT d.database_id, d.name, d.create_date,
       CASE WHEN reasons.Detail IS NULL THEN N'PENDING' ELSE N'SKIPPED' END,
       reasons.Detail
FROM sys.databases AS d
CROSS APPLY
(
    SELECT CASE
        WHEN d.source_database_id IS NOT NULL THEN N'数据库快照'
        WHEN d.is_distributor = 1 OR d.name = N'distribution' THEN N'分发数据库'
        WHEN d.state_desc <> N'ONLINE' THEN N'数据库非 ONLINE：' + d.state_desc
        WHEN d.is_read_only = 1 THEN N'只读数据库'
        WHEN d.user_access_desc <> N'MULTI_USER' THEN N'数据库非 MULTI_USER'
        WHEN ISNULL(HAS_DBACCESS(d.name), 0) <> 1 THEN N'当前连接无法访问数据库'
        WHEN ISNULL(CONVERT(NVARCHAR(60), DATABASEPROPERTYEX(d.name, N'Updateability')), N'')
             <> N'READ_WRITE' THEN N'数据库当前不可写（可能为辅助副本）'
        ELSE NULL
    END AS Detail
) AS reasons
WHERE d.database_id > 4;

DECLARE @DB SYSNAME, @DatabaseId INT, @DatabaseCreateDate DATETIME;
DECLARE @SQL NVARCHAR(MAX), @FixSQL NVARCHAR(MAX), @ID INT;
DECLARE @DatabaseUser SYSNAME, @LoginName SYSNAME, @UserPrincipalId INT;
DECLARE @OriginalUserSID VARBINARY(85), @LoginSID VARBINARY(85);
DECLARE @ReadyStatus NVARCHAR(32) =
    CASE WHEN @Execute = 1 THEN N'PENDING' ELSE N'PREVIEW' END;

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT DatabaseId, DatabaseName, DatabaseCreateDate
FROM #OrphanRepairDatabases
WHERE Status = N'PENDING'
ORDER BY DatabaseName;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DatabaseId, @DB, @DatabaseCreateDate;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @SQL = CAST(N'' AS NVARCHAR(MAX)) + N'
USE ' + QUOTENAME(@DB) + N';

IF NOT EXISTS
(
    SELECT 1 FROM master.sys.databases
    WHERE database_id = @ExpectedDatabaseId
      AND name = DB_NAME()
      AND create_date = @ExpectedCreateDate
      AND state_desc = N''ONLINE''
      AND is_read_only = 0
      AND user_access_desc = N''MULTI_USER''
)
    THROW 51010, N''数据库身份或可写状态已变化，请重新扫描。'', 1;

INSERT INTO #OrphanRepairUsers
(
    DatabaseId, DatabaseName, DatabaseUser, UserPrincipalId,
    OriginalUserSID, LoginName, LoginSID, FixSQL, Status, Detail
)
SELECT DB_ID(), DB_NAME(), dp.name, dp.principal_id,
       dp.sid, sl.name, sl.sid,
       CASE WHEN sl.principal_id IS NOT NULL
                  AND sl.is_disabled = 0 AND mapped.principal_id IS NULL
            THEN N''USE '' + QUOTENAME(DB_NAME()) COLLATE DATABASE_DEFAULT
                 + N''; ALTER USER '' + QUOTENAME(dp.name) COLLATE DATABASE_DEFAULT
                 + N'' WITH LOGIN = '' + QUOTENAME(sl.name) COLLATE DATABASE_DEFAULT + N'';''
            ELSE NULL END,
       CASE WHEN sl.principal_id IS NULL THEN N''NO_LOGIN''
            WHEN sl.is_disabled = 1 THEN N''DISABLED_LOGIN''
            WHEN mapped.principal_id IS NOT NULL THEN N''LOGIN_IN_USE''
            ELSE @ReadyStatus END,
       CASE WHEN sl.principal_id IS NULL THEN N''未找到名称完全一致的 SQL Login；请人工确认映射或迁移 Login。''
            WHEN sl.is_disabled = 1 THEN N''同名 SQL Login 已禁用；跳过自动修复。''
            WHEN mapped.principal_id IS NOT NULL THEN N''目标 Login SID 已映射给其他数据库用户。''
            ELSE N''候选映射：请确认该同名 Login 确实属于这个数据库用户。'' END
FROM sys.database_principals AS dp
-- 二进制匹配并检查字节长度，避免数据库排序规则合并不同名称。
LEFT JOIN sys.sql_logins AS sl
  ON dp.name COLLATE Latin1_General_100_BIN2 = sl.name COLLATE Latin1_General_100_BIN2
 AND DATALENGTH(dp.name) = DATALENGTH(sl.name)
OUTER APPLY
(
    SELECT TOP (1) dp2.principal_id
    FROM sys.database_principals AS dp2
    WHERE dp2.sid = sl.sid AND dp2.principal_id <> dp.principal_id
) AS mapped
WHERE dp.type = ''S''
  AND dp.authentication_type_desc = ''INSTANCE''
  AND dp.principal_id > 4
  AND NOT EXISTS
  (
      SELECT 1 FROM sys.server_principals AS sp WHERE sp.sid = dp.sid
  );
';
    BEGIN TRY
        EXEC sys.sp_executesql @SQL,
             N'@ReadyStatus NVARCHAR(32), @ExpectedDatabaseId INT, @ExpectedCreateDate DATETIME',
             @ReadyStatus = @ReadyStatus,
             @ExpectedDatabaseId = @DatabaseId,
             @ExpectedCreateDate = @DatabaseCreateDate;

        UPDATE #OrphanRepairDatabases SET Status = N'SCANNED'
        WHERE DatabaseId = @DatabaseId;
    END TRY
    BEGIN CATCH
        UPDATE #OrphanRepairDatabases
        SET Status = N'FAILED', ErrorNumber = ERROR_NUMBER(), Detail = ERROR_MESSAGE()
        WHERE DatabaseId = @DatabaseId;
    END CATCH;
    FETCH NEXT FROM db_cursor INTO @DatabaseId, @DB, @DatabaseCreateDate;
END;
CLOSE db_cursor;
DEALLOCATE db_cursor;

IF @Execute = 1
BEGIN
    DECLARE fix_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT u.ID, u.DatabaseId, u.DatabaseName, d.DatabaseCreateDate,
           u.DatabaseUser, u.UserPrincipalId, u.OriginalUserSID,
           u.LoginName, u.LoginSID, u.FixSQL
    FROM #OrphanRepairUsers AS u
    INNER JOIN #OrphanRepairDatabases AS d ON d.DatabaseId = u.DatabaseId
    WHERE u.Status = N'PENDING' AND d.Status = N'SCANNED'
    ORDER BY u.ID;

    OPEN fix_cursor;
    FETCH NEXT FROM fix_cursor INTO @ID, @DatabaseId, @DB, @DatabaseCreateDate,
        @DatabaseUser, @UserPrincipalId, @OriginalUserSID, @LoginName, @LoginSID, @FixSQL;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @SQL = CAST(N'' AS NVARCHAR(MAX)) + N'
USE ' + QUOTENAME(@DB) + N';
BEGIN TRY
    BEGIN TRANSACTION;

    IF NOT EXISTS
    (
        SELECT 1 FROM master.sys.databases
        WHERE database_id = @ExpectedDatabaseId
          AND name = DB_NAME() AND create_date = @ExpectedCreateDate
          AND state_desc = N''ONLINE'' AND is_read_only = 0
          AND user_access_desc = N''MULTI_USER''
    ) OR ISNULL(CONVERT(NVARCHAR(60), DATABASEPROPERTYEX(DB_NAME(), N''Updateability'')), N'''')
         <> N''READ_WRITE''
        THROW 51010, N''数据库身份或可写状态已变化，请重新扫描。'', 1;

    IF NOT EXISTS
    (
        SELECT 1 FROM sys.database_principals
        WHERE principal_id = @ExpectedUserId AND sid = @ExpectedUserSID
          AND name COLLATE Latin1_General_100_BIN2 = @ExpectedUserName COLLATE Latin1_General_100_BIN2
          AND DATALENGTH(name) = DATALENGTH(@ExpectedUserName)
          AND type = ''S'' AND authentication_type_desc = ''INSTANCE''
    )
        THROW 51011, N''数据库用户已变化，请重新扫描。'', 1;

    IF NOT EXISTS
    (
        SELECT 1 FROM sys.sql_logins
        WHERE sid = @ExpectedLoginSID AND is_disabled = 0
          AND name COLLATE Latin1_General_100_BIN2 = @ExpectedLoginName COLLATE Latin1_General_100_BIN2
          AND DATALENGTH(name) = DATALENGTH(@ExpectedLoginName)
    )
        THROW 51012, N''目标 Login 已变化或被禁用，请重新扫描。'', 1;

    IF EXISTS (SELECT 1 FROM sys.server_principals WHERE sid = @ExpectedUserSID)
        THROW 51013, N''该用户已不再孤立，请重新扫描。'', 1;

    IF EXISTS
    (
        SELECT 1 FROM sys.database_principals
        WHERE sid = @ExpectedLoginSID AND principal_id <> @ExpectedUserId
    )
        THROW 51014, N''目标 Login 已映射其他用户，请人工处理。'', 1;

    EXEC sys.sp_executesql @Command;

    IF NOT EXISTS
    (
        SELECT 1 FROM sys.database_principals
        WHERE principal_id = @ExpectedUserId AND sid = @ExpectedLoginSID
    )
        THROW 51020, N''修复后 SID 校验失败，已回滚。'', 1;

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
';
        BEGIN TRY
            EXEC sys.sp_executesql @SQL,
                N'@ExpectedDatabaseId INT, @ExpectedCreateDate DATETIME,
                  @ExpectedUserId INT, @ExpectedUserSID VARBINARY(85), @ExpectedUserName SYSNAME,
                  @ExpectedLoginSID VARBINARY(85), @ExpectedLoginName SYSNAME, @Command NVARCHAR(MAX)',
                @ExpectedDatabaseId = @DatabaseId, @ExpectedCreateDate = @DatabaseCreateDate,
                @ExpectedUserId = @UserPrincipalId, @ExpectedUserSID = @OriginalUserSID,
                @ExpectedUserName = @DatabaseUser, @ExpectedLoginSID = @LoginSID,
                @ExpectedLoginName = @LoginName, @Command = @FixSQL;

            UPDATE #OrphanRepairUsers
            SET Status = N'SUCCESS', Detail = N'映射完成，SID 校验通过。'
            WHERE ID = @ID;
        END TRY
        BEGIN CATCH
            -- USE 失败发生在动态批次的事务之前；其他异常由内层 CATCH 回滚。
            IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
            UPDATE #OrphanRepairUsers
            SET Status = CASE WHEN ERROR_NUMBER() BETWEEN 51010 AND 51014
                              THEN N'SKIPPED' ELSE N'FAILED' END,
                ErrorNumber = ERROR_NUMBER(), Detail = ERROR_MESSAGE()
            WHERE ID = @ID;
        END CATCH;
        FETCH NEXT FROM fix_cursor INTO @ID, @DatabaseId, @DB, @DatabaseCreateDate,
            @DatabaseUser, @UserPrincipalId, @OriginalUserSID, @LoginName, @LoginSID, @FixSQL;
    END;
    CLOSE fix_cursor;
    DEALLOCATE fix_cursor;
END;

-- 1. 孤立用户明细；FixSQL 为 NULL 的条目需要人工处理。
SELECT DatabaseName, DatabaseUser, LoginName, OriginalUserSID, LoginSID,
       FixSQL, Status, ErrorNumber, Detail
FROM #OrphanRepairUsers
ORDER BY DatabaseName, DatabaseUser;

-- 2. 用户状态汇总（只有上述扫描范围内的 INSTANCE SQL 用户）。
SELECT Status, COUNT(*) AS UserCount
FROM #OrphanRepairUsers
GROUP BY Status
ORDER BY Status;

-- 3. 数据库覆盖范围：SCANNED、SKIPPED、FAILED，不能仅用用户数判断扫描是否完整。
SELECT DatabaseName, Status, ErrorNumber, Detail
FROM #OrphanRepairDatabases
ORDER BY DatabaseName;

DROP TABLE #OrphanRepairUsers;
DROP TABLE #OrphanRepairDatabases;
