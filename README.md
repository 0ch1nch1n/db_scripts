# db_scripts

个人数据库脚本库，收集日常运维、故障排查和维护中使用的脚本，按数据库类型和用途分类。

## 脚本索引

| 数据库 | 分类 | 脚本 | 用途 | 默认模式 |
| --- | --- | --- | --- | --- |
| SQL Server | 安全与权限 | [批量修复孤立 SQL 用户](sqlserver/security/repair_orphaned_users/) | 扫描孤立 SQL 用户，并将符合条件的用户重新映射到现有同名 SQL Login | 仅预览 |
| Oracle 19c | 巡检与诊断 | [Oracle Health Check v3.1](oracle/diagnostics/health_check/) | 维护前采集基线，维护后比较本机实例、PDB、服务和对象状态 | 采集与比较（需指定 before / after） |
| PostgreSQL 11+ | 安全与权限 | [统一 schema 对象 owner](postgresql/security/change_schema_object_owner/) | 将指定 schema 内常见对象转移给同一角色，区分重载并处理依附序列 | 仅预览（修订版） |
| PostgreSQL | 安全与权限 | [导出用户/角色迁移 DDL](postgresql/security/migrate_roles/) | 生成角色、角色参数和成员关系的迁移 SQL，不包含密码及对象授权 | 仅查询并输出 DDL |

点击脚本名称查看详细说明，包括适用版本、所需权限、参数、运行方法和验证情况。

SQL Server 孤立用户修复脚本已由维护者验证可用（反馈日期：2026-10-24），默认仍为仅预览。

## 目录结构

每项脚本使用独立目录，将代码、说明和相关文件放在一起。

```text
db_scripts/
├── README.md
├── oracle/
│   └── diagnostics/
│       └── health_check/
│           ├── README.md
│           ├── health_check_v3_1.sh
│           ├── VALIDATION.md
│           ├── .gitignore
│           └── tests/
│               └── verify_health_check.py
├── postgresql/
│   └── security/
│       ├── change_schema_object_owner/
│       │   ├── README.md
│       │   ├── change_schema_object_owner.sql
│       │   └── archive/
│       │       └── change_schema_object_owner.original.sql
│       └── migrate_roles/
│           ├── README.md
│           └── export_roles.sql
└── sqlserver/
    └── security/
        └── repair_orphaned_users/
            ├── README.md
            └── repair_orphaned_users.sql
```

目录按 `数据库类型/用途分类/脚本名称/` 组织；文件和目录使用小写英文及下划线，便于查找和引用。

随着脚本增加，再按需要创建 `mysql/` 等数据库目录，以及 `backup/`、`maintenance/`、`diagnostics/` 等用途分类。

## 使用约定

- 运行前先阅读对应脚本目录中的 README，确认适用环境、权限和参数。
- 涉及数据库修改的脚本，在支持时默认提供预览或显式执行开关；具体行为以各脚本说明为准。
- 每个脚本分别记录验证情况；收录进仓库不代表已经通过生产环境验证。
- 提交前移除密码、连接凭据和环境敏感信息。

## 新增脚本

1. 在对应数据库和分类下，新建一个能够说明用途的脚本目录。
2. 放入脚本和 `README.md`，说明用途、适用版本、权限、参数、运行示例、影响范围和验证情况。
3. 在本页“脚本索引”中增加一行，链接到该脚本目录。
4. 日常修改使用 Git 提交历史管理；仅在需要保留独立参考版本时使用 `archive/`，避免不断添加 `v1`、`v2` 或 `final` 文件。
