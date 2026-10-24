# PostgreSQL：导出非系统用户/角色迁移 DDL

## 导出内容

| 内容 | 范围或行为 |
| --- | --- |
| 角色 | 默认排除名称以 pg_ 或 rds 开头的角色，其余角色生成 CREATE ROLE |
| 角色属性 | SUPERUSER、INHERIT、CREATEROLE、CREATEDB、LOGIN、REPLICATION、BYPASSRLS、连接数限制及密码有效期限 |
| 角色注释 | 生成 COMMENT ON ROLE |
| 角色参数 | 导出角色的全局设置，以及角色在当前连接数据库的设置 |
| 成员关系 | 两端角色都在选中范围时生成 GRANT |
| 跨筛选边界的成员关系 | 生成 REVIEW SYSTEM/EXCLUDED MEMBERSHIP 注释，供人工检查 |
| 密码 | 不导出明文或密码哈希，只输出单独设置密码的提醒 |

角色属于集群级对象，不是某个 schema 的局部对象；但角色的按数据库参数只导出当前连接数据库这一部分。完整迁移所有数据库的角色参数需要额外整理。

## 使用方法

1. 在源集群选定数据库连接运行脚本，确认该连接能够读取所需系统目录。
2. 查看 selected_roles 中的筛选条件。建议启用已有的 allowlist 示例，只选本次要迁移的业务角色。
3. 导出查询结果中的 ddl 单列，保留生成顺序，不要复制列标题、边框或行数提示。
4. 人工检查 CREATE ROLE 的属性、角色参数、GRANT 和 REVIEW 注释，适配目标环境。
5. 在目标集群准备好涉及的数据库和角色管理权限，再执行复核后的 DDL；本工具不连接目标集群。
6. 为需要密码认证的 LOGIN 角色单独设置密码，并验证登录、角色继承及实际业务权限。

## 使用边界与需要复核的内容

- **名称前缀只是筛选约定**，并不等于 PostgreSQL 或云厂商的完整系统角色识别。postgres、其他厂商管理角色，以及不以这些前缀开头的管理员角色仍可能被选中；自定义 rds 前缀角色则会被排除。
- 源码中的 REVIEW 注释仅针对成员关系跨越筛选边界的情况。选中角色的 SUPERUSER、CREATEROLE、REPLICATION、BYPASSRLS 等属性仍会生成可执行 DDL，范围内的高权限成员关系也不会自动降级成注释。
- 源库 PostgreSQL 16+ 时，成员授权使用 ADMIN / INHERIT / SET 选项语法；较早源库使用旧式 GRANT。**分支依据源库版本，而不是目标库版本**，跨版本迁移需检查目标语法和继承语义。
- 代码使用 to_jsonb 读取不同版本的成员选项列，但这不表示已经验证所有 PostgreSQL 版本。生成结果仍受目标版本、角色管理权限和托管数据库限制影响。
- 被筛选掉一端的成员关系只生成复核注释，其中没有完整表达 PostgreSQL 16+ 的 INHERIT / SET 选项；如需恢复，应在源库核对后另行整理。
- 不保留成员授权的原始 grantor 身份。一个角色对可能对应多条来自不同 grantor 的记录，不保证生成结果去重。
- 角色参数按原稿使用 SET ... TO 单个字符串生成。search_path、预加载库等列表型参数必须检查生成语句及目标 SHOW 结果，不能仅以执行成功判断参数语义完全一致。
- 按数据库设置中保留源数据库名称；目标数据库改名时需修改对应 ALTER ROLE ... IN DATABASE 语句。当前库之外的按数据库角色设置不在导出范围内。
- CREATE ROLE 没有 IF NOT EXISTS 或合并逻辑；目标已有同名角色时会失败。不要直接用重跑来代替角色差异检查。
- 不导出对象 owner、数据库/schema/表/序列/函数等对象授权、默认权限、RLS 策略或认证配置。角色成功创建不等于完成数据库权限迁移。
- 脚本不读取 pg_authid 中的密码字段。“密码无法迁移”是原稿对本工具边界的说明，不代表 PostgreSQL 在所有场景下都无法迁移密码哈希。

## 输出顺序

1. CREATE ROLE。
2. COMMENT ON ROLE。
3. ALTER ROLE 的全局及当前数据库参数。
4. 选中范围内的成员关系。
5. 系统/排除角色相关的复核注释。
6. 密码设置提醒。

导出的 DDL 没有自动事务包装，也没有遇错回滚流程；目标库执行行为由使用的客户端和事务设置决定。

## 参考资料

- [CREATE ROLE](https://www.postgresql.org/docs/current/sql-createrole.html)
- [ALTER ROLE](https://www.postgresql.org/docs/current/sql-alterrole.html)
- [GRANT](https://www.postgresql.org/docs/current/sql-grant.html)
- [pg_roles](https://www.postgresql.org/docs/current/view-pg-roles.html)
- [pg_auth_members](https://www.postgresql.org/docs/current/catalog-pg-auth-members.html)
- [pg_db_role_setting](https://www.postgresql.org/docs/current/catalog-pg-db-role-setting.html)
