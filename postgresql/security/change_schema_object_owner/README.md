# PostgreSQL：统一 schema 内常见对象的 owner

[返回仓库首页](../../../README.md)

将当前数据库中指定 schema 的常见对象转移给同一角色。默认 schema 和目标角色均为 `empf_rpa`。

[脚本](change_schema_object_owner.sql)：默认仅预览。

## 适用范围

需要 PostgreSQL 11+，使用 `pg_proc.prokind` 区分函数和存储过程。脚本只处理当前连接的数据库，不会遍历整个 PostgreSQL 集群。

| 对象 | 处理方式 |
| --- | --- |
| 普通表、分区表 | 使用 ALTER TABLE ONLY，按本 schema 的对象逐一处理 |
| 外部表 | 使用 ALTER FOREIGN TABLE |
| 视图、物化视图 | 使用对应 ALTER 语句 |
| 独立序列 | 表处理完成后再修改 |
| SERIAL / IDENTITY 等依附字段的序列 | 随所属表自动迁移，不直接修改序列 owner |
| 普通函数、存储过程 | 按每个对象自身的 OID 生成完整身份参数，区分重载 |
| 扩展成员 | 输出 SKIP EXTENSION，交由扩展维护流程处理 |
| 已属于目标角色的对象 | 跳过；执行模式中，随表自动迁移的序列也计入此类 |

“schema 内所有对象”不是此脚本的完整承诺。它不单独处理 schema 本身、类型、域、聚合函数、窗口函数、排序规则、运算符、文本搜索对象、默认权限或其他对象类别。索引、TOAST 及依附序列等由 PostgreSQL 的表所有权变更机制处理。

## 使用方法

1. 连接到正确的目标数据库。确认 schema 和角色已存在。
2. 修改脚本顶部三个参数：

```sql
v_target_schema TEXT := 'empf_rpa';
v_target_owner TEXT := 'empf_rpa';
v_execute BOOLEAN := false;
```

3. 完整运行脚本，查看客户端的 NOTICE / WARNING 输出。`[PREVIEW]` 后是待执行 SQL；预览不会执行 ALTER，也不证明执行权限已经满足。
4. 检查扩展跳过项、依附序列和 BLOCKED 信息。确认所有权转移范围后，将 `v_execute` 改为 `true`，重新运行整个脚本。
5. 执行成功后再次以预览模式运行，检查待执行项和跳过原因。已有目标 owner 的对象不再生成 ALTER。

从仓库根目录使用 psql 的示例：

```bash
psql -X -v ON_ERROR_STOP=1 -d your_database -f postgresql/security/change_schema_object_owner/change_schema_object_owner.sql
```

该命令使用脚本中保存的参数；初始文件为预览模式。连接身份通过已有的 PostgreSQL 认证配置选择。

客户端需显示 NOTICE 消息，例如 psql 的默认消息设置；图形客户端通常位于“消息”或“输出”面板。

## 执行权限与事务

通常需要拥有原对象的修改权限，能够 SET ROLE 到目标角色，且目标角色对所在 schema 有 CREATE 权限；具体角色成员关系和版本规则以服务器检查为准。超级用户按 PostgreSQL 的权限规则处理。脚本不自动授予权限、不创建角色，也不修改 schema owner。

执行模式不会逐对象忽略错误。整个 DO 块在一个事务中运行：任一对象修改或 owner 校验失败，将回滚本次 DO 块的所有变更。在显式事务内运行时，DO 成功也仍需由调用方 COMMIT；遇错后需由调用方处理失败事务。NOTICE 中的中间 EXECUTE 信息不表示事务已经提交。

本脚本可能持有多项 DDL 锁直到事务结束，大 schema 上应评估锁等待和执行时间。不要同时运行对象创建、删除、重命名、扩展更新或其他 owner 变更。

## 依附序列和跨 schema 影响

- 依附序列与所属表的 owner 必须保持一致，不能简单对每个序列执行 ALTER SEQUENCE OWNER。
- 预览时，所属表在本次范围内的依附序列标记为 INDIRECT，表示预计由表的变更自动处理；不会生成单独的 ALTER SEQUENCE。
- 如果目标 schema 内的序列依附于其他 schema 的表，或所属表因扩展成员等原因未纳入范围，且序列还不属于目标角色，预览标记为 BLOCKED。执行模式会报错并回滚，要求先人工确定所属表的处理方式。
- 表所有权变更会自动处理其关联序列、索引和 TOAST 等对象。**关联序列可能在其他 schema**，因此按 schema 筛选表不代表所有间接影响都局限于这个 schema。执行前需要核对依赖。
- 序列循环会重新读取 owner，因此能识别此前表变更带来的自动迁移。

## 权限语义与边界

所有权转移会改变谁能管理对象。SECURITY DEFINER 函数或过程将以新 owner 的权限运行，执行前必须确认这一变化符合预期。

脚本不复制旧角色的角色成员关系或其他授权，不重新设计已有 GRANT，不修改默认权限或 RLS 策略。新 owner 的权限和 RLS 绕过行为可能与旧 owner 不同；相关业务访问需分别验证。

## 验证记录

维护者已验证当前脚本可用（反馈日期：2026-10-27）。本记录依据维护者反馈，未记录具体 PostgreSQL 版本、测试环境和覆盖场景。

此前于 2026-10-23 完成静态逻辑检查，核对分区表命令、按 OID 区分重载、依附序列路径、默认预览及失败回滚逻辑，并检查 SQL 字符串/注释/括号配对与文档相对链接。

## PostgreSQL 参考资料

- [ALTER TABLE](https://www.postgresql.org/docs/current/sql-altertable.html)
- [ALTER SEQUENCE](https://www.postgresql.org/docs/current/sql-altersequence.html)
- [ALTER FUNCTION](https://www.postgresql.org/docs/current/sql-alterfunction.html)
- [ALTER PROCEDURE](https://www.postgresql.org/docs/current/sql-alterprocedure.html)
- [pg_proc](https://www.postgresql.org/docs/current/catalog-pg-proc.html)
- [pg_depend](https://www.postgresql.org/docs/current/catalog-pg-depend.html)
