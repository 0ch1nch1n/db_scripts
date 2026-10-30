# PostgreSQL Schema 迁移验证脚本 v1.0

适用场景：把指定 schema 迁移到另一个数据库，schema 名保持不变。默认检查 `public`；可通过 `schemas` 参数指定一个或多个 schema。

不需要 Python、dblink、FDW 或数据库扩展。采集和比对都通过 psql 完成；比对只需要连接任意一个允许创建临时对象的 PostgreSQL 数据库。

要求：psql 12+、PostgreSQL 12+，数据库账号具有 CONNECT、TEMP 和所需对象的读取权限。设计按 PostgreSQL 12–18 共有目录字段编写；实际测试版本见 VALIDATION.md。请用独立 psql 会话运行，不要在已有业务事务里运行。不支持只读事务/禁止临时 DDL 的连接。

## 1. 最短用法

将本目录的脚本保存到同一目录，在该目录打开终端。三个命令均写成单行，可用于 PowerShell、CMD、macOS/Linux 终端。替换主机、账号和数据库名；密码由 psql 提示或使用已配置的 pgpass，不写进脚本。

源库采集：

```text
psql -X -h SOURCE_HOST -U CHECK_USER -d SOURCE_DB -v output_file=source.csv -f collect.sql
```

目标库采集：

```text
psql -X -h TARGET_HOST -U CHECK_USER -d TARGET_DB -v output_file=target.csv -f collect.sql
```

比对：

```text
psql -X -h TARGET_HOST -U CHECK_USER -d TARGET_DB -f compare.sql
```

执行后检查：

| 文件 | 用途 |
|---|---|
| source.csv | 源库快照 |
| target.csv | 目标库快照 |
| comparison.txt | 数据库身份、采集时间、对象数量、差异摘要、检查结果 |
| differences.csv | 每个差异的对象名称及源/目标完整明细；支持 Excel/文本编辑器查看 |

输出路径相对于 psql 当前工作目录，不是 SQL 文件目录。比较脚本默认从当前目录读取 `source.csv`、`target.csv`。所有默认输出会覆盖同名文件；历史验收请先另存目录。

采集开始会清空指定输出文件；失败时不要使用该文件继续验收。最终 CSV 有完成标记及记录数量校验，比对会拒绝明显截断/不完整的快照。采集成功仍须检查 collection_errors；比较也会将这些错误列为 ERROR。

## 2. pgAdmin 的 PSQL Tool 用法

在**源库连接**打开 PSQL Tool，执行（路径自行替换，Windows 建议正斜杠）：

```text
\cd 'C:/DBA/schema_migration_verifier'
\set output_file source.csv
\i collect.sql
```

在**目标库连接**打开另一个 PSQL Tool：

```text
\cd 'C:/DBA/schema_migration_verifier'
\set output_file target.csv
\i collect.sql
\i compare.sql
```

两个窗口必须使用同一客户端文件目录；如果运行于不同电脑，先把 CSV 放到一起再比对。本包包含 psql 元命令，不能在普通 Query Tool 中直接执行。

如果 PSQL Tool 中途报错并返回提示符，重新运行前先执行 `ROLLBACK;`，或打开新的 PSQL Tool 窗口。

## 3. 参数

| 参数 | 默认 | 说明 |
|---|---|---|
| schemas | public | 逗号分隔，区分大小写；schema 名本身不能含逗号；两侧必须相同 |
| output_file | snapshot.csv | collect.sql 的 CSV 输出路径 |
| check_rows | true | 精确 COUNT(*)，可能扫描大表 |
| check_data | false | 全表内容指纹；开启后自动同时计算行数 |
| statement_timeout | 0 | 服务器 statement_timeout；0 不限时；DO 中的数据循环整体受该时间限制 |
| report_file | comparison.txt | compare.sql 文本报告路径 |
| diff_file | differences.csv | compare.sql 差异 CSV 路径 |
| strict | false | true 时，有任何 DIFF/REVIEW/ERROR 则在写完报告后抛错，psql 返回非零 |

只检查结构，跳过扫描表数据（两侧使用相同参数）：

```text
psql -X -h SOURCE_HOST -U CHECK_USER -d SOURCE_DB -v output_file=source.csv -v check_rows=false -f collect.sql
```

检查指定 schema，并开启内容指纹（源、目标都要开启）：

```text
psql -X -h SOURCE_HOST -U CHECK_USER -d SOURCE_DB -v schemas=app -v output_file=source.csv -v check_data=true -f collect.sql
```

在 PSQL Tool 中设置参数：

```text
\set schemas 'app'
\set check_rows true
\set check_data true
\set statement_timeout '30min'
\set output_file source.csv
\i collect.sql
```

PSQL Tool 的变量会在会话中保留；修改后重新采集，或使用新窗口。collect.sql 会 ROLLBACK 它创建的事务和临时对象。

## 4. 检查覆盖范围

| 类别 | 本版自动采集/比较 |
|---|---|
| 关系对象 | 普通表、分区父表/子表、外部表、普通/物化视图、序列、普通/分区索引、独立复合类型 |
| 表结构 | 逻辑字段顺序、类型/长度、NOT NULL、默认值、IDENTITY、生成列、列排序规则 |
| 分区/继承 | 分区键、边界、父对象；按对象实际所在 schema 归属 |
| 约束 | 表约束定义、验证状态、延迟属性；NOT NULL 统一通过列定义比较 |
| 程序对象 | 函数/过程/窗口函数完整重建定义；按名称和参数签名识别重载；聚合函数仅主要属性 |
| 其他定义 | 用户触发器及启用状态、用户 Rule、RLS Policy、枚举标签、Domain 主要定义/约束、外部表服务器名称及表级选项 |
| 数据 | 本地普通表/叶子分区精确行数；可选全表内容指纹 |
| 序列 | 类型、起始/增量/上下限/cache/cycle、列所有权关联、last_value/is_called |
| 状态 | 无效/未 ready/删除中的索引、未验证约束、物化视图是否 populated |
| 权限 | schema/表/视图/序列/函数/过程 Owner、有效默认 ACL 和显式 ACL、列级 ACL、相关 schema 及全局 default privileges |
| 环境 | 数据库版本/编码/排序规则、数据库内扩展名称和版本 |

数量摘要是对象清单汇总，包含分区及其克隆对象；它不是原始 SQL 中“排除子分区的业务表数”。COLUMN 等支持记录不计入数量摘要。不要把不同对象类别简单相加解释成业务对象总数。

默认不比较 OID、filenode、文件大小、统计信息、物理 dropped-column 空槽。Owner/权限单独列为 SECURITY，避免与结构差异混淆。没有做角色名映射，因此合理的账号替换仍会产生 REVIEW。

跨 PostgreSQL 大版本时，系统目录反解析出的定义文本可能不同，即使语义相同也会列为 DIFF；需要人工复核，脚本不会自动执行任何修复。

## 5. 结果解释

| 结果 | 含义 |
|---|---|
| MATCH | 本次配置、覆盖范围内，没有发现差异；不是完整迁移成功证明 |
| DIFF | 结构/对象清单/行数/内容指纹不同 |
| REVIEW | 权限、环境、序列状态、物化视图状态、异常对象等需要人工判断 |
| ERROR | 至少一侧对象数据/序列采集失败；权限不足不会算作 0，也不会算作一致 |

差异类型：SOURCE_ONLY = 源有目标无；TARGET_ONLY = 目标多出对象；CHANGED = 同一对象的定义或数据指标不同。

健康异常即使两侧完全相同，也会保留 REVIEW，要求确认它是否为已知源库基线。顺序优先 ERROR → DIFF → REVIEW → MATCH。

默认非 strict 模式：脚本运行成功仅代表报告生成成功，不代表没有差异。自动化调用建议加 `-v strict=true`，仍要阅读报告。输入文件错误、缺少 schema 或全局 SQL 错误会立即终止，psql 返回非零。

## 6. 数据、序列与一致性边界

- 停写、同步追平后再比较，或使用迁移方案规定的一致基线。两侧 REPEATABLE READ 事务分别建立快照，**不是跨数据库同步快照**。长时间全表扫描会占用 I/O 并持有快照，应安排窗口。
- COUNT(*) 使用 `ONLY`，避免传统继承重复统计；实际叶子分区单独检查。位于未选中 schema 的子分区不会采集；把相关 schema 一起传入。
- 会设置 `row_security=off`，防止 RLS 悄悄过滤行；无权绕过 RLS 时会记录 ERROR。账号仍须有对象 SELECT 权限。外部表和物化视图数据不在本版自动数据扫描范围内。
- 内容指纹算法：每行 `md5(to_jsonb(row)::text)`，对两个 64 位半段分别转为数值求和，并比较行数；保留重复行的影响、与行顺序无关、不把全表拼成字符串。它是概率校验，不等于逐字段证明；跨版本/类型序列化差异可能导致差异，需要复核。脚本统一 timezone、datestyle、intervalstyle、浮点和 bytea 显示设置。
- 指纹会读取完整行，包含大字段；性能开销比单纯 COUNT(*) 更高。JSON 等值可能按规范化语义比较，非字节级比较；大对象 OID 引用不代表大对象实际内容已比较。
- 序列状态不受 REPEATABLE READ 的一致性保证；cache、并发和恢复策略可能使 last_value 不同，所以列为 REVIEW。脚本不调用 nextval/setval。**状态相同也不证明下次插入不会冲突**：切换前按实际序列方向/cache/cycle及对应字段最大/最小值复核，必要的修复另走变更。
- check_data=false 时，即使行数相同，也没有验证数据内容；两侧都关闭 check_rows/check_data 时，只能得出结构范围内的结果。报告首段显示采集选项和时间。

## 7. 仍需人工验收

1. 检查迁移/恢复日志没有未处理错误；用真实应用账号验证连接、schema USAGE、search_path、序列权限和业务查询/写入。
2. 关键视图、函数、过程和触发器做业务测试。定义相同不保证外部依赖存在或执行成功。脚本不自动执行业务写入、不自动刷新物化视图、不执行 ANALYZE/修复 SQL。
3. 跨 schema 依赖、角色成员关系、登录属性、数据库/角色级设置、PUBLIC/default privileges 的业务含义，及外部服务器连接/User Mapping，需另外确认；不导出 User Mapping 密码。
4. 本版不是 pg_dump 的替代品：未覆盖注释、表空间、访问方法、存储/压缩细节、全部类型属性、range/multirange/自定义 base type、collation 定义、operator/operator class、扩展二进制依赖、完整复杂聚合定义、event trigger、publication/subscription、全局对象及大对象内容。重要迁移仍建议补充同版本 pg_dump --schema-only 定义比对。
5. 快照含表/函数定义和访问控制信息；函数体或外部表选项可能包含原本嵌入其中的敏感配置，应按数据库导出物管理，不上传不必要的业务数据。

建议验收：核实采集身份和时间 → 确认采集无 ERROR → 处理结构/数据 DIFF → 审核 REVIEW → 应用账号业务测试。

参考：PostgreSQL 官方文档 [psql](https://www.postgresql.org/docs/17/app-psql.html)、[系统信息函数](https://www.postgresql.org/docs/17/functions-info.html)、[pg_index](https://www.postgresql.org/docs/17/catalog-pg-index.html)、[pg_sequence](https://www.postgresql.org/docs/17/catalog-pg-sequence.html)、[pg_dump](https://www.postgresql.org/docs/17/app-pgdump.html)。
