# db_scripts

数据库运维脚本。

## SQL Server：批量修复孤立 SQL 用户

- [建议使用：修订版](sqlserver/security/repair_orphaned_users.sql)
- [原始版本存档](sqlserver/security/archive/repair_orphaned_users.original.sql)

两份脚本都默认 `@Execute = 0`，仅扫描和预览。原始版本为本次提供的脚本存档；后续维护以修订版为准。

### 可用性检查结论

原脚本的核心处理方法正确：用 SID 判断数据库用户是否失去服务器登录映射，并用 `ALTER USER ... WITH LOGIN` 将用户重新映射到现有 SQL Login。角色成员关系和显式权限通常保留，不需要删除重建用户。

但它适合特定范围，不能等同于“整个实例全部孤立用户都已修复”：

| 检查点 | 原脚本行为 | 修订版处理 |
| --- | --- | --- |
| 用户类型 | 仅 `SQL_USER` 且 `INSTANCE` 身份验证 | 保留该范围；不处理 Windows 用户、Windows 组、contained 用户或外部身份 |
| 目标 Login | 只处理存在同名 SQL Login 的用户，其余不输出 | 输出所有符合范围的孤立 SQL 用户，区分可修复和需人工处理 |
| 元数据权限 | 权限不足时可能看不到其他 Login，导致误判或漏报 | 扫描和执行都要求 sysadmin；这是本脚本的运行前提，并非 ALTER USER 的最低权限要求 |
| 名称匹配 | DATABASE_DEFAULT 能解决排序规则冲突，但在服务器区分大小写、数据库不区分大小写等配置下，可能匹配多个 Login | 使用 Latin1_General_100_BIN2 和 DATALENGTH，只自动映射名称完全一致的 Login；大小写或重音差异需要人工确认 |
| 同名身份 | 技术上可映射，但名称相同不能证明身份相同 | 默认预览，并明确要求人工确认映射意图 |
| Login 禁用 | 仍会尝试映射，但不能解决登录被禁用的问题 | 输出 DISABLED_LOGIN，不自动启用或映射 |
| Login 已被其他用户占用 | 排除但不输出 | 输出 LOGIN_IN_USE，交由人工处理 |
| 预览 SQL | 缺少 USE，复制出来执行可能落在错误数据库 | 每行包含完整 USE [数据库]; ALTER USER ... |
| 扫描与执行间的变化 | 直接执行之前生成的语句 | 执行前复核数据库 ID/创建时间、用户 ID/名称/SID、Login 名称/SID/启用状态及映射冲突 |
| 单条修复 | TRY/CATCH 记录语句成功或失败 | 每个用户独立事务，修复后核对 SID，失败回滚该用户 |
| 数据库覆盖 | 跳过的数据库不显示 | 输出每个用户数据库的 SCANNED、SKIPPED 或 FAILED 及原因 |
| 重复运行 | 同一连接中上次异常遗留的临时表可能导致建表失败 | 开始时清理本脚本专用临时表 |
| 长动态 SQL | 当前长度可用，扩展时需留意中间表达式截断 | 使用 NVARCHAR(MAX) 拼接起点，避免中间表达式的 4000 字符截断 |

### 使用方法

1. 使用 SQL Server 2012 或更新版本，以 sysadmin 连接运行。适用目标为 SQL Server 实例；不适用于 Azure SQL Database。
2. 使用专门的会话，确保没有活动事务，且 IMPLICIT_TRANSACTIONS 为 OFF。
3. 在 SSMS、Azure Data Studio 或 sqlcmd 中运行完整修订版。GO 是客户端批次分隔符；通过驱动调用时，应由调用方拆分批次。
4. 首次保留 `DECLARE @Execute BIT = 0;`，查看三个结果集：孤立用户明细、用户状态汇总、数据库扫描结果。
5. 确认所有候选映射的 Login 确实对应这些数据库用户；有不应映射的条目时，先调整脚本范围，不能直接批量执行。
6. 将 `@Execute` 改为 1，再运行完整脚本。此模式会重新扫描并处理当次全部符合条件的用户，并非执行之前保存的预览清单。
7. 修复后以 `@Execute = 0` 再运行，确认已修复条目不再被列为孤立，并检查所有数据库的扫描状态。

请优先使用脚本的执行模式。单独复制 FixSQL 执行会绕过脚本中的身份复核、事务及修复后验证。

### 状态说明

| 用户状态 | 含义 |
| --- | --- |
| PREVIEW | 满足自动映射条件，仅预览，未修改 |
| NO_LOGIN | 没有名称完全一致的 SQL Login；可能需要手工指定其他 Login，或迁移原 Login 及其 SID |
| DISABLED_LOGIN | 同名 SQL Login 被禁用，需要人工确认 |
| LOGIN_IN_USE | 同名 Login 的 SID 已映射其他数据库用户 |
| PENDING | 执行模式中等待处理的内部状态；正常完成时不应遗留 |
| SUCCESS | 当前用户修复并通过 SID 校验 |
| SKIPPED | 执行前发现身份或映射状态发生变化，未执行该条修复 |
| FAILED | SQL 执行失败，查看 ErrorNumber 和 Detail |

数据库结果中的 SCANNED 表示扫描完成，不等于存在可修复用户；SKIPPED 表示未进入扫描范围；FAILED 表示扫描失败。

### 范围和运行注意事项

- 仅扫描运行开始时存在的用户数据库；排除系统库、快照、分发库、非 ONLINE、只读、非 MULTI_USER、不可访问或当前不可写的数据库。辅助副本等不可写数据库会跳过或报告错误。
- 不创建、删除或启用 Login，不修改密码，不修复 dbo/数据库所有者，不自动合并已有用户。修复映射也不保证应用立即能登录，登录模式、禁用状态、数据库访问及其他权限需要分别确认。
- 已有任何服务器主体 SID 映射的用户不算本脚本的孤立用户，即使 Login 名称与用户名不同；不会强行改成同名 Login。
- 不要与数据库还原、删除重建、重命名、AG 切换或用户/Login DDL 并发运行。执行前复核可发现常见状态变化，但不提供跨数据库的原子快照，也不能消除复核与 ALTER USER 之间的所有并发窗口。
- 逐用户提交，因此部分成功、部分失败是可能的；不会在一个用户失败后回滚之前已成功的用户。DDL 可能等待锁，运行时安排合适的维护窗口。
- 结果保存在会话临时表中，结束后删除；如需审计，请保存三个结果集。中断或连接断开可能无法得到完整结果，应重新扫描。

### 验证记录（2026-10-23）

本次完成了人工静态逻辑审查、外层 SQL 及两段展开后动态 SQL 的引号/注释/括号配对检查，并对中文、右方括号、单引号及含 SQL 片段的数据库名进行了 QUOTENAME 转义检查。默认预览、权限检查、独立事务、身份复核和修复后 SID 校验均已检查。

**尚未通过 SQL Server 编译或实机执行验证。** 本次云端执行环境启动失败，没有可用的 SQL Server 测试实例；上述词法检查不能代替 T-SQL 解析器或数据库集成测试。本次未连接或修改任何生产数据库。

生产使用前，应在隔离测试实例验证：

| 场景 | 预期结果 |
| --- | --- |
| 同名 SQL Login，SID 不同，Login 启用 | 预览为 PREVIEW；执行为 SUCCESS；角色和显式权限保留 |
| 上述场景以 Execute=0 运行 | 用户 SID 不变，未执行 ALTER USER |
| 用户已有有效 SID 映射，Login 名称不同 | 不列为孤立、不修改 |
| 无同名 Login | NO_LOGIN，不创建 Login |
| 同名 Login 禁用 | DISABLED_LOGIN，不启用 |
| 同名 Login 已映射其他用户 | LOGIN_IN_USE，不修改 |
| 服务器 CS、数据库 CI，同时存在大小写不同的 Login | 只匹配字符和长度完全一致的 Login，不产生多个候选 |
| 数据库、用户或 Login 名称含 ]、单引号、中文 | 标识符正确转义；预览 USE 指向正确数据库 |
| Windows 用户、contained 用户、dbo | 不进入修复范围 |
| 只读/离线/快照/辅助副本/单用户数据库 | 跳过并说明，或记录具体扫描错误 |
| 非 sysadmin，或调用方已有事务/开启隐式事务 | 扫描前报错退出 |
| Execute=1 修复后再次扫描 | 已成功映射的用户不再出现在孤立列表 |

### Microsoft 参考资料

- [排查孤立用户](https://learn.microsoft.com/sql/sql-server/failover-clusters/troubleshoot-orphaned-users-sql-server)
- [ALTER USER](https://learn.microsoft.com/sql/t-sql/statements/alter-user-transact-sql)
- [元数据可见性](https://learn.microsoft.com/sql/relational-databases/security/metadata-visibility-configuration)
- [数据库主体目录视图](https://learn.microsoft.com/sql/relational-databases/system-catalog-views/sys-database-principals-transact-sql)
