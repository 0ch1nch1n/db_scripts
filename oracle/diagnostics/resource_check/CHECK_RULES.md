# Oracle Resource Check v2.1 判断规则

本版侧重月度巡检的汇总与异常清单。使用方法和参数见 [README.md](README.md)。采集端要求 Bash 4+、oraenv、SQL*Plus 12.2+ 和本机 OS SYSDBA；报表仅使用 Python 3.8+ 标准库。

## 连接与采集范围

- 逐库、逐模块串行执行，共 7 个模块。每个模块独立尝试候选本地 SID，失败后继续后续模块。
- 首先检查 `DB_NAME`，可选检查 `DB_UNIQUE_NAME`，然后切换并确认目标 PDB；UNDO 从 root 采集。
- PDB 为空时，CDB 仅检查 root，non-CDB 检查该数据库；不会自动遍历全部 PDB。
- SID 不代表远程连接，不会 SSH 到其他 RAC 节点；`GV$` 仅读取当前连接可见实例。
- `TWO_TASK`、`LOCAL` 仅在采集子进程中清除；CSV 固定 UTF-8 环境，派生 CSV 使用 UTF-8 BOM。
- 查询字典和动态视图，执行会话级设置；不执行业务表扫描、统计收集、账号修改、SHRINK、MOVE、REBUILD 或 Advisor 任务。

## 表空间与 UNDO

- 普通表空间：当前容量、当前已用/空闲、数据文件配置扩展上限、两种使用率。
- 默认按 **当前容量**、严格 **`>90%`** 告警。
- `--basis MAX` 改为按配置最大容量判断；两种使用率仍同时输出。
- `configured_max_gb` 是数据文件配置上限，**没有检查 ASM/文件系统实际剩余容量**。
- TEMP 用 `DBA_TEMP_FREE_SPACE` 中包含可复用空间的口径。若容量汇总与 tempfile 总容量不匹配，标 `REVIEW`，不猜测百分比。实例本地 TEMP 的复杂布局需在首轮运行中核对。
- 非 ONLINE 表空间列为待复核，不把缺失空闲信息当成正常。
- UNDO 容量保留在 `tablespace.csv`；使用情况单独查看 `undo.csv`。

UNDO：

- 从 CDB root 检测 local/shared undo，读取 `GV$UNDOSTAT` 的各实例最近采样桶，结合容器/表空间/数据文件容量。
- 展示 ACTIVE、UNEXPIRED、EXPIRED 容量，ACTIVE+UNEXPIRED 的占比，以及采样桶中的 `SSOLDERRCNT`、`NOSPACEERRCNT`、`UNXPSTEALCNT`。
- 这不是对其他实例执行 `DBA_UNDO_EXTENTS` 状态估算，也不是逐行实时测量。
- 最近桶有上述错误/争用事件标 `ALERT`；保留空间比例超阈值标 `REVIEW`，不把 UNEXPIRED 当成永久不可复用空间。
- 超过 30 分钟的采样、缺少映射/容量或未知模式标 `REVIEW`。PDB 在某实例未打开时标 `PDB_NOT_OPEN`。
- shared undo 检查的是 CDB 共用资源，可能在多个 PDB 月报中重复展示，**不能把这些重复结果相加**。
- 当前脚本只读取最近采样桶，不宣称覆盖整月或全部近四天；不同 RU、容器可见性或表空间切换可能需要现场核对映射。

## 统计信息：计数和待复核明细

范围为 `ORACLE_MAINTAINED='N'` 的用户，保留表/索引及分区、子分区统计记录。

- 缺失：`LAST_ANALYZED` 为空。
- 过期：`STALE_STATS='YES'`；不能仅凭分析日期旧就判为过期。
- 锁定：`STATTYPE_LOCKED` 非空，需要结合应用策略复核。
- 未知：`STALE_STATS` 既不是 YES 也不是 NO，保留复核提示。
- 特殊表/索引继续列为待复核；索引状态无法匹配时保留未知状态提示。
- 普通索引及其分区/子分区为 `UNUSABLE` 时，保留到 `statistics_review.csv`，不执行重建。

SQL 中先分类，再按 Schema、对象类型把正常记录压缩成 `SUMMARY` 数量；待复核对象为 `DETAIL`，保留对象、分区身份、统计作用域 SCOPE 和状态。正常对象名、正常对象最后分析时间及全量按月分布不再输出。报告端还会校验记录类型、正整数数量、重复记录和对象身份，异常数据按模块失败处理。

`statistics_summary.csv` 的 `checked_count` 是正常计数加待复核记录数；`review_count` 是待复核记录数。缺失、过期、锁定、未知、不可用计数可能重叠，不能相加当作唯一异常数。`unknown_count` 表示过期状态未知，不等于所有特殊对象数量；完整待复核范围以 `review_count` 和明细为准。

分区表父级、分区及不同统计作用域分别计为统计记录，不等于唯一逻辑表数；没有任何统计记录时提示 `REVIEW`，不会凭空判定正常。

## 空间浪费候选检查

不再比较历史 run，不再采集索引段大小和结构指标。空间项只表示本次快照中的候选和估算覆盖。

### 表估算

1. 按顶层表检查可支持范围，仅对普通非分区、非压缩堆表估算。
2. 要求统计分析时间存在、`STALE_STATS='NO'`，且行数、平均行长、块大小和 PCTFREE 等输入可用。
3. 使用 `NUM_ROWS × AVG_ROW_LEN`、块大小和 PCTFREE 估算块需求，再与表段分配量比较。
4. 默认同时满足估算浪费 **>100 MB 且 >30%** 才输出对象明细；阈值在采集时经 Shell 验证后传给 SQL，报表使用本次 run 的阈值再次校验。

锁定统计信息不必然等于估算不可靠；如果分析时间、过期状态及输入满足条件，仍可进入估算，但统计模块会保留锁定提示。

### 覆盖与结果

- `table_waste_candidates.csv` 只含可靠堆表候选；分区、压缩、IOT、临时、外部、嵌套等表不做估算。
- `table_waste_summary.csv` 按 Schema、`method_status` 汇总：`ESTIMATED`、`UNSUPPORTED_PARTITIONED`、`UNSUPPORTED_TABLE_TYPE`、`UNSUPPORTED_COMPRESSED`、`NO_TABLE_SEGMENT`、`UNRELIABLE_STATS`、`MISSING_INPUT_STATS`。
- 每张顶层表归入一个主要原因；表有多个限制时，只计入首先命中的原因。正常非候选及跳过对象不保留全量对象名，保留数量；统计信息不可靠的对象可在统计复核明细中查找。
- `checked_count` 为已估算表数；`issue_count` 为候选数。存在候选、跳过表或没有可估算表时为 `REVIEW`。只有存在已估算表、无候选且无跳过表时，此项可为 `OK`，含义限于当前规则和范围。
- 一个 Schema 中已估算数量包含候选；`candidate_count` 是该数量的子集，不能重复相加。
- 表段不含 LOB、LOBINDEX 或其他索引段；不支持的表即使有段也不估算。

这是依赖字典统计的粗略估算，未精确建模全部行/块开销；不等于实际可回收容量或已确认碎片率，也不会自动推荐维护。需要深入检查时，对少量重点对象人工选择适合的空间工具。

## 功能账号

正式文件 `functional_accounts.csv` 故意留空，避免猜测哪些是功能账号。请根据真实账号填写；示例见 `functional_accounts.example.csv`，示例占位名称不能直接当实际账号使用。

| 列名 | 含义 |
|---|---|
| `database` | `db_list.conf` 第一列数据库标签 |
| `username` | 字典中的实际用户名；普通账号通常为大写，按原样精确匹配 |
| `expected_status` | 预期状态，通常为 `OPEN`；故意锁定账号可填 `LOCKED` |
| `expiry_warning_days` | 提前多少天提示到期，空值采用运行参数，默认 30 |

范围说明：

- 原始账号明细为 `ORACLE_MAINTAINED='N'` 的账号；不是“所有账号都是功能账号”。
- 不在清单中的账号保留在 `account_review.csv`，标为 `UNCLASSIFIED`，不自动纳入功能账号结论。
- 清单中账号没查到会标 `EXPECTED_ACCOUNT_NOT_FOUND`；故意锁定且实际符合预期的标 `OK_EXPECTED_STATUS`。
- 状态不符、已过期、即将到期、需要外部认证核实的账号均待复核。
- `OK_NO_RECORDED_EXPIRY` 仅表示账号处于预期 OPEN 状态且字典中没有记录到期日，不表示已测试登录。
- `NONE`/外部/全局认证不凭 `OPEN` 判定登录有效；需要复核实际认证机制。
- 最近登录时间仅供参考，不自动据此判定账号“不活跃”。SYSDBA 等管理连接不会填充该字段。
- 如需加入系统维护账号，本版需另行调整账号采集范围；清单包含但被过滤的账号会显示未找到。

## 状态与失败处理

| result | 含义 |
| --- | --- |
| `OK` | 本次规则与范围内未发现待复核项 |
| `ALERT` | 表空间越线或最近 UNDO 桶观察到错误/争用事件 |
| `REVIEW` | 有待复核项、缺少业务范围或估算覆盖不足 |
| `FAILED` | 采集/CSV 校验失败，不能视为没有异常 |

退出码 `0` 只说明执行完成，不代表没有告警；`1` 为采集/报表失败，`2` 为参数/依赖错误。失败模块会影响相应月报项目，不会伪装成正常。

## 输出与版本

`monthly_summary.csv` / `.md` 保留每库四项：`TABLESPACE`、`TABLE_AND_INDEX_STATISTICS`、`SPACE_WASTE_CANDIDATES`、`FUNCTIONAL_ACCOUNT_VALIDITY`。其中索引不可用状态归入统计复核。

v2.1 采集 CSV 是压缩格式，仅配套 v2.1 报表；不接受旧 v2.0 run 和 `--baseline`，不生成表/索引变化报表。旧 run 请使用 Git 历史中的配套 v2.0 报表。重新执行报表只覆盖该 run 的派生报表，不会修改数据库。

## 资源与验证边界

SQL 内先压缩正常对象，减少传输、CSV 和 Python 内存需求；跳过独立索引结构查询及历史比较。字典查询仍需读取、关联和分组，异常很多时明细也可能很大，没有固定耗时和资源比例保证。当前没有查询超时和资源限额，首次仍应低峰期单库试跑。

一次快照不能代表整月峰值；脚本不创建定时任务，不借助 AWR/ASH 推断历史。SQL 尚未在实际 Oracle 19c/RU/SQL*Plus 环境验证。离线流程、真实 SQL 文本的模拟字典测试和限制见 [VALIDATION.md](VALIDATION.md)。

## Oracle 官方参考

- [V$UNDOSTAT：采样间隔、空间和错误指标](https://docs.oracle.com/en/database/oracle/oracle-database/19/refrn/V-UNDOSTAT.html)
- [DBA_UNDO_EXTENTS：跨 RAC 实例状态查询的限制](https://docs.oracle.com/en/database/oracle/oracle-database/19/refrn/DBA_UNDO_EXTENTS.html)
- [CDB local/shared undo 模式](https://docs.oracle.com/en/database/oracle/oracle-database/19/multi/administering-a-cdb-with-sql-plus.html)
- [DBA_TEMP_FREE_SPACE：可复用空间口径](https://docs.oracle.com/en/database/oracle/oracle-database/19/refrn/DBA_TEMP_FREE_SPACE.html)
- [统计信息过期的判断](https://docs.oracle.com/en/database/oracle/oracle-database/19/tgsql/gathering-optimizer-statistics.html)
- [ALL_IND_STATISTICS / DBA_IND_STATISTICS 字段](https://docs.oracle.com/en/database/oracle/oracle-database/19/refrn/ALL_IND_STATISTICS.html)
- [DBA_USERS：账号状态、到期、认证和最近登录](https://docs.oracle.com/en/database/oracle/oracle-database/19/refrn/DBA_USERS.html)
- [DBMS_SPACE：进一步空间复核工具](https://docs.oracle.com/en/database/oracle/oracle-database/19/arpls/DBMS_SPACE.html)
- [SQL*Plus SET 与 CSV 输出](https://docs.oracle.com/en/database/oracle/oracle-database/19/sqpug/SET-system-variable-summary.html)
