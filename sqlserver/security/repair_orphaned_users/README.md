# SQL Server：批量修复孤立 SQL 用户

## 功能与适用范围

- 处理 `SQL_USER` 且使用 `INSTANCE` 身份验证的用户，不处理 Windows 用户、Windows 组、contained 用户或外部身份。
- 使用二进制排序规则及名称长度匹配同名 SQL Login；只有 Login 启用且未被其他用户占用时才进入自动修复范围。同名身份需要人工确认。
- 预览包含完整的 `USE [数据库]; ALTER USER ...` 语句；无匹配 Login、Login 禁用或映射冲突的条目会单独报告。
- 执行前复核数据库、用户和 Login 身份；逐用户使用独立事务，修复后校验 SID。
- 输出孤立用户明细、用户状态汇总及数据库扫描结果，便于确认处理范围。

## 使用方法

1. 使用 SQL Server 2012 或更新版本，以 sysadmin 连接运行。适用目标为 SQL Server 实例；不适用于 Azure SQL Database。
2. 使用专门的会话，确保没有活动事务，且 IMPLICIT_TRANSACTIONS 为 OFF。
3. 在 SSMS、Azure Data Studio 或 sqlcmd 中运行完整脚本。GO 是客户端批次分隔符；通过驱动调用时，应由调用方拆分批次。
4. 首次保留 `DECLARE @Execute BIT = 0;`，查看三个结果集：孤立用户明细、用户状态汇总、数据库扫描结果。
5. 确认所有候选映射的 Login 确实对应这些数据库用户；有不应映射的条目时，先调整脚本范围，不能直接批量执行。
6. 将 `@Execute` 改为 1，再运行完整脚本。此模式会重新扫描并处理当次全部符合条件的用户，并非执行之前保存的预览清单。
7. 修复后以 `@Execute = 0` 再运行，确认已修复条目不再被列为孤立，并检查所有数据库的扫描状态。

请优先使用脚本的执行模式。单独复制 FixSQL 执行会绕过脚本中的身份复核、事务及修复后验证。

## 状态说明

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

## 范围和运行注意事项

- 仅扫描运行开始时存在的用户数据库；排除系统库、快照、分发库、非 ONLINE、只读、非 MULTI_USER、不可访问或当前不可写的数据库。辅助副本等不可写数据库会跳过或报告错误。
- 不创建、删除或启用 Login，不修改密码，不修复 dbo/数据库所有者，不自动合并已有用户。修复映射也不保证应用立即能登录，登录模式、禁用状态、数据库访问及其他权限需要分别确认。
- 已有任何服务器主体 SID 映射的用户不算本脚本的孤立用户，即使 Login 名称与用户名不同；不会强行改成同名 Login。
- 不要与数据库还原、删除重建、重命名、AG 切换或用户/Login DDL 并发运行。执行前复核可发现常见状态变化，但不提供跨数据库的原子快照，也不能消除复核与 ALTER USER 之间的所有并发窗口。
- 逐用户提交，因此部分成功、部分失败是可能的；不会在一个用户失败后回滚之前已成功的用户。DDL 可能等待锁，运行时安排合适的维护窗口。
- 结果保存在会话临时表中，结束后删除；如需审计，请保存三个结果集。中断或连接断开可能无法得到完整结果，应重新扫描。

## 验证记录

- **2026-10-24：维护者反馈已验证当前脚本可用。**
- 2026-10-23：完成静态逻辑检查、动态 SQL 字符串/注释/括号配对和特殊数据库名转义检查。

## Microsoft 参考资料

- [排查孤立用户](https://learn.microsoft.com/sql/sql-server/failover-clusters/troubleshoot-orphaned-users-sql-server)
- [ALTER USER](https://learn.microsoft.com/sql/t-sql/statements/alter-user-transact-sql)
- [元数据可见性](https://learn.microsoft.com/sql/relational-databases/security/metadata-visibility-configuration)
- [数据库主体目录视图](https://learn.microsoft.com/sql/relational-databases/system-catalog-views/sys-database-principals-transact-sql)
