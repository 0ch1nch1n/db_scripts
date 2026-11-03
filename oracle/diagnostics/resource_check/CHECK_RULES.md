# Oracle Resource Check v2.0

用于月度 Oracle 资源维护检查：表空间、表/索引统计信息、空间变化复核、功能账号有效性。

本工具以独立目录收录。Shell、Python、SQL 和离线测试沿用 v2.0 附件原文；公开配置已替换为通用示例，来源与改动见 `source-manifest.json`。

## 快速开始

1. 在 Oracle 数据库主机上解压，使用能够执行 `/ as sysdba` 的操作系统账号。
2. 检查 `db_list.conf`。仓库仅包含通用示例，必须替换为真实数据库和当前主机可用的 SID/PDB 映射；建议将实际清单保存为已忽略的 `db_list.local.conf`，并用 `--db-list` 指定。
3. 填写 `functional_accounts.csv`。默认只有表头；不填时账号明细仍会采集，但功能账号结论显示 `REVIEW`。
4. 在解压目录执行：

```bash
bash check_resources.sh
```

每次在 `output/` 下新建独立 `run_时间戳_随机后缀/`，不会覆盖其他运行结果。

先只检查一个数据库时，另建一份仅含该数据库配置行的 `db_list_test.conf`：

```bash
bash check_resources.sh --db-list db_list_test.conf
```

每个 run 目录中优先查看：

| 文件 | 用途 |
|---|---|
| `monthly_summary.csv` | 每库四项维护结论、执行状态、待复核数量及证据路径 |
| `monthly_summary.md` | 简短月报概览，可在 Obsidian 中打开 |
| `execution_status.csv` | 每库、每模块、每个候选 SID 的成功/失败记录 |
| `statistics_summary.csv` | 按 Schema、对象类型、分析月份和检查状态汇总 |
| `table_waste_candidates.csv` | 超过两个阈值的表空间浪费估算候选项 |
| `table_space_changes.csv` | 本次与指定历史基线的表空间估算变化 |
| `index_space_changes.csv` | 索引段大小、层级、叶块数、统计行数的变化 |
| `account_review.csv` | 全部已采集账号及功能账号检查结论 |
| `report_errors.csv` | CSV 格式、字段、数字解析等报表错误；没有错误时只有表头 |
| `数据库名/*.csv` | 对应数据库的原始检查明细 |
| `数据库名/logs/*.log` | 各次连接尝试/模块执行的错误信息 |

主脚本退出码：`0` 执行完成，`1` 有采集或报表失败，`2` 参数或依赖错误。
`0` **不代表没有发现异常**：例如使用率告警、统计信息待复核，会显示在月报中。

## 环境与连接方式

- 目标版本为 Oracle Database **19c**；数据库主机需要 Bash **4+**、`oraenv`、SQL*Plus **12.2+**（建议 19c 客户端）。
- 自动生成报表需要 Python **3.8+**，只使用标准库，无需 pip 包。
- 连接方式沿用原脚本的本机 OS 认证 `/ as sysdba`。`oraenv` 必须能通过 PATH 找到。
- SID 列表是**当前主机可尝试的本地实例**。不会 SSH 到另一个 RAC 节点，也不会把远端 SID 自动变成远程连接。
- 每个模块分别尝试候选 SID；一个模块失败不会阻止其他模块。`GV$` 用于读取可见 RAC 实例数据。
- `TWO_TASK`、`LOCAL` 只在采集子进程中清除，避免环境变量将连接重定向到远端；父进程环境不改动。
- CSV 采集子进程固定 `NLS_LANG=AMERICAN_AMERICA.AL32UTF8`；报表 CSV 使用 UTF-8 BOM，方便 Excel 打开。
- 未进行 listener/端口测试，也不验证应用使用其密码能否登录。Host/Port 不参与本机 SYSDBA 连接。
- 脚本仅查询字典/动态视图，执行会话级容器、数字格式和时区设置。不会执行统计信息收集、账号修改、SHRINK、MOVE、REBUILD 或 Advisor 分析任务。

如果数据库主机没有 Python，可以只采集：

```bash
bash check_resources.sh --collect-only
```

然后将**整个 run 目录**和 `report.py` 复制到装有 Python 3.8+ 的 Mac/其他主机，执行：

```bash
python3 report.py /path/to/collected_run_directory
```

Mac 自带 Bash 可能是 3.2；本机生成报表只需要 Python，不需要运行采集 shell。

## 数据库配置

```text
# database_label|local_sid1/local_sid2|expected_db_name|pdb|optional_expected_db_unique_name
APP_PDB|ORCL1/ORCL2|ORCL|APPPDB|ORCL_PRIMARY
```

- 前四列为必填结构；第五列可选，填写真实 `DB_UNIQUE_NAME` 后会额外校验，建议用于区分同名生产/备库。
- 第三列核对的是 `V$DATABASE.NAME`，即 `DB_NAME`，并非 PDB 名或服务名。
- PDB 为空：CDB 只检查 root；non-CDB 检查该数据库。**不会自动遍历全部 PDB**。
- PDB 非空：先核对数据库身份，再检查/切换指定 PDB。容器切换失败不会继续当成成功结果。
- 数据库标签用于目录名，需要唯一，仅支持字母/数字/下划线开头和后续字母/数字/点/短横线。
- SID、DB_NAME、DB_UNIQUE_NAME、PDB 只支持普通未加双引号的 Oracle 标识符，不接受空格、SQL 片段或带引号标识符。
- 分隔符两边不要加空格；支持 CRLF，`#` 开头整行注释。

## 功能账号清单

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

## 四项检查的判断口径

### 1. 表空间

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

### 2. 表/索引统计信息

- 明细包括表、索引、分区/子分区对象的最后分析时间、`STALE_STATS`、统计锁定状态。
- 缺失、过期、未知、特殊对象、锁定统计信息列为待复核；不会只因为日期较旧就判定过期。
- 特殊索引、临时/外部表等可能有不同的合理统计策略，结果应结合应用策略处理。
- 同一分区表可能有父级和分区多条统计记录；`checked_count` 是统计记录数，不是唯一逻辑表数量。
- 本版不自动收集统计信息，也没有预设应用对象豁免规则。

### 3. 表/索引空间变化与碎片复核

- `table_waste.csv` 保留**所有非系统维护用户下的顶层表清单**，而非仅保留超阈值表。
- 只对可支持的普通非分区、非压缩堆表做基于 `NUM_ROWS × AVG_ROW_LEN`、块大小、PCTFREE 的粗略估算。
- 分区表、压缩表、IOT、外部/临时/嵌套表等保留清单和 `method_status`，不生成不可靠估算。
- 表段容量可以汇总表分区段，但不含 LOB、LOBINDEX 或其他索引段；分区表不会因此被当成已支持估算。
- 候选默认同时满足估算浪费 **>100 MB 且 >30%**；`STALE_STATS` 非 NO 时先复核统计信息。
- 对行/块开销、数据分布等只做简化处理。估算浪费 **不等于实际可回收容量，也不等于已经确认的碎片率**。
- 索引段明细涵盖普通索引段及其分区/子分区，输出段大小、BLEVEL、LEAF_BLOCKS、CLUSTERING_FACTOR 等结构指标。没有分配段的索引仍可出现在统计信息明细中。
- **索引结构指标不是碎片率；本版不通过某个 BLEVEL、CLUSTERING_FACTOR 或大小增长就推荐 REBUILD。**
- 对重点对象可后续人工使用适合其段类型的 `DBMS_SPACE`/已有 Segment Advisor 结果复核。本版不自动运行这些额外检查。
- 碎片项首次为 `NO_BASELINE`；提供基线后仍为 `REVIEW`，并列明估算变化和覆盖缺口，不输出未经证实的“没有碎片增加”。

### 4. 功能账号有效性

依据显式清单、状态、到期信息与认证类型检查。范围和状态含义见上文账号清单章节。

## 基线比较

第一次执行先保存完整 run 目录。后续指定一个**真实存在的、更早的 v2 run 目录**：

```bash
bash check_resources.sh --baseline /path/to/previous_run_directory
```

也可以仅重新生成已有采集结果的报表：

```bash
python3 report.py /path/to/current_run_directory --baseline /path/to/previous_run_directory
```

- 不会自动选择、覆盖或推进基线；v1 报表缺少必要身份/对象信息，不直接作为 v2 基线。
- DBID、DB_UNIQUE_NAME、容器名和容器 DBID 必须一致，避免跨库或 PDB 重建后错误比较。
- 对象 ID、DATA_OBJECT_ID 或 LAST_DDL_TIME 改变时标为对象变更待复核，不直接计算成碎片变化。
- 表估算比较还要求两次均为支持的估算对象，且统计信息均为 `STALE_STATS=NO`。
- 新增/新纳入范围、移除/移出范围、缺失基线、基线采集失败分别标识；不把对象未出现直接推断为 DROP。
- 索引变化只说明结构/分配变化；业务增长、统计信息更新、对象维护都可能影响结果。
- 默认没有“增长达到多少才重要”的公司标准；任一正的表浪费估算变化列为待复核，实际变化量同时输出。
- 重新运行 `report.py` 会重写该 run 中的派生报表，保留采集 CSV、设置、原基线和日志。不要同时对同一 run 生成两份报表。

## 可选参数

```bash
bash check_resources.sh --help
```

例如：

```bash
bash check_resources.sh --threshold 90 --basis CURRENT --waste-mb 100 --waste-pct 30 --expiry-days 30
```

支持 `--db-list`、`--accounts`、`--output`、`--baseline`。数据文件/SQL 路径含空格时请在命令中正确加引号。

## 月报填写建议

脚本不直接填写月报中的 Yes/No，因为那可能分别代表“已检查”或“发现异常”。

| result | 含义 |
|---|---|
| `OK` | 在本次采集、明确范围和规则下未发现待处理项，不表示整月持续正常 |
| `ALERT` | 观察到使用率越线或 UNDO 事件，需关注 |
| `REVIEW` | 有待复核项、未配置业务范围、特殊对象或测量覆盖不足 |
| `NO_BASELINE` | 没有比较基线，不能判断是否增加 |
| `FAILED` | 采集/数据解析失败，不能当作“未发现异常” |

`issue_count` 是已识别的检查项/对象记录数量，不是全量风险计数；尤其碎片项的覆盖缺口应同时阅读 remarks。

每月只执行一次得到的是一次快照。若月报实际要求“整月是否曾超过 90%”，必须另有周期采样和月内峰值汇总；本版不创建定时任务，也不借助 AWR/ASH 进行历史推断。

## 验证状态

开发环境通过了 Bash 语法检查、Python 编译检查和 18 项离线测试。离线测试覆盖 SP2 零退出码错误、静默非零退出码、逐模块 SID 重试、模块失败后继续、无基线、数据库/对象身份变化、统计信息可靠性、账号预期状态及 CSV 转义等。

**发布验证没有连接实际 Oracle，尚未在目标数据库/RU/SQL*Plus 客户端上编译执行这些 SQL。** 请先用一库配置运行，确认 `execution_status.csv`、原始明细和月报口径，再扩展到全部清单。

离线测试可再次执行，不连接数据库：

```bash
python3 -m unittest discover -s tests -v
bash -n check_resources.sh
```

`original_sha256.json` 是附件内沿用的六个更早文件的历史哈希记录；这些更早文件未随包提供，本次未验证。当前 ZIP 来源与逐文件核对见 `source-manifest.json`；公开目录校验使用 `SHA256SUMS`。

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
