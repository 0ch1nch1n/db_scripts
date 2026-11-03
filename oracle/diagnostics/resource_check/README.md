# Oracle Resource Check v2.1

Oracle 月度资源巡检工具：通过本机 OS SYSDBA 采集字典数据，用 Python 生成汇总和待复核清单。各库、各模块串行执行。

## 检查内容

| 项目 | v2.1 行为 |
| --- | --- |
| 表空间 / UNDO | 永久、TEMP、UNDO 容量和使用情况；默认按当前容量严格 `>90%` 告警；UNDO 查看可见实例最近采样桶 |
| 表 / 索引统计信息 | 正常对象在 SQL 中按 Schema、对象类型压缩计数；仅导出缺失、过期、锁定、未知及特殊对象等待复核明细 |
| 空间浪费候选 | 仅对统计信息可靠的普通非分区、非压缩堆表估算；默认同时 `>100 MB` 且 `>30%` 才保留对象明细；其他表保留数量和跳过原因 |
| 索引状态 | 由统计信息模块检查 `UNUSABLE`，包括分区/子分区；不再采集索引段大小、BLEVEL、叶块数及结构趋势 |
| 功能账号 | 根据显式清单检查预期状态、到期窗口和认证类型；未配置清单时返回 `REVIEW` |

共 7 个采集模块：`metadata`、`tablespace`、`undo`、`table_stats`、`index_stats`、`table_waste`、`user_accounts`。模块失败后可重试下一本地 SID，保留每次执行结果。

## 环境与影响

- Oracle Database 19c；具体 RU、CDB/PDB、RAC、non-CDB 兼容性需单库现场验证。
- 采集主机需要 Bash 4+、PATH 中的 `oraenv`、SQL*Plus 12.2+（建议 19c），以及能够执行 `/ as sysdba` 的操作系统账号。
- 报表需要 Python 3.8+，仅使用标准库，可移到 Mac 或其他主机生成。
- 仅查询字典/动态视图并设置会话容器、数值格式和时区；不会扫描业务表内容、收集统计信息、修改账号或执行空间维护。
- 正常统计记录和非候选表在 SQL 输出前压缩，可减少 CSV 和 Python 内存开销；字典仍需查询和分组，不能保证数据库耗时按相同比例下降。独立索引结构查询已移除。
- 大库首次应在低峰期只配置一个数据库试跑。当前没有 SQL 超时或资源限额。

## 使用

公开配置为通用示例，实际数据库映射没有上传。先复制并编辑本地配置：

```bash
cp db_list.conf db_list.local.conf
cp functional_accounts.csv functional_accounts.local.csv
bash check_resources.sh --db-list db_list.local.conf --accounts functional_accounts.local.csv
```

数据库清单：

```text
# database_label|local_sid1/local_sid2|expected_db_name|pdb|optional_expected_db_unique_name
APP_PDB|ORCL1/ORCL2|ORCL|APPPDB|ORCL_PRIMARY
```

前四列保留，PDB 可为空，第五列可选。脚本核对数据库身份；PDB 留空时 CDB 仅检查 root，不会遍历所有 PDB。SID 为本机可尝试的实例，不会跨 RAC 节点连接。

功能账号格式见 [functional_accounts.example.csv](functional_accounts.example.csv)。默认账号清单只有表头，不猜测业务范围，账号元数据也不能证明应用登录成功。

`*.local.conf`、`*.local.csv` 和默认 `output/` 已忽略；自定义输出目录应放在仓库外。

## 分开采集和生成报表

```bash
bash check_resources.sh --db-list db_list.local.conf --accounts functional_accounts.local.csv --collect-only
```

将整个生成的 run 目录和本版 `report.py` 复制到 Python 主机后执行：

```bash
python3 report.py /path/to/collected_run_directory
```

重新执行报表会重写当前 run 的派生报表，保留采集文件和日志。不要同时对同一 run 生成报表。

## 参数

| 参数 | 默认值 / 用途 |
| --- | --- |
| `--db-list FILE` | `db_list.conf`；数据库映射 |
| `--accounts FILE` | `functional_accounts.csv`；功能账号清单 |
| `--output DIR` | `output/`；每次新建独立 run 目录 |
| `--threshold NUMBER` | `90`；使用率严格大于阈值 |
| `--basis CURRENT\|MAX` | `CURRENT`；当前容量或配置最大容量 |
| `--waste-mb NUMBER` | `100`；表估算候选严格大于该 MB 值 |
| `--waste-pct NUMBER` | `30`；候选还须严格大于该百分比 |
| `--expiry-days INTEGER` | `30`；账号到期提醒窗口，可按账号覆盖 |
| `--collect-only` | 只采集 |
| `--help` | 查看帮助 |

## 看哪些结果

| 文件 | 用途 |
| --- | --- |
| `monthly_summary.csv` / `.md` | 每库四项结论、执行状态和范围说明 |
| `execution_status.csv` | 7 个模块及候选 SID 的执行记录 |
| `statistics_summary.csv` | 每库、Schema、对象类型的检查数、待复核数及缺失/过期/锁定/未知/不可用数量 |
| `statistics_review.csv` | 统计信息待复核和 `UNUSABLE` 索引明细，保留分区身份 |
| `table_waste_candidates.csv` | 符合两个阈值的可靠堆表估算候选 |
| `table_waste_summary.csv` | 各 Schema 的已估算表数、候选数和跳过原因数量 |
| `account_review.csv` | 账号明细与功能账号判断 |
| `report_errors.csv` | CSV 和压缩记录校验错误 |
| `数据库标签/*.csv`、`logs/` | 原始采集结果和日志；统计及浪费原始文件已为压缩格式 |

退出码：`0` 执行完成，仍可能有 `ALERT` 或 `REVIEW`；`1` 采集/报表失败；`2` 参数、配置或依赖错误。没有符合条件的对象、存在跳过范围、缺少业务账号清单时会提示复核。

## v2.1 格式变化

本版移除历史基线比较和 `--baseline`，不再生成 `table_space_changes.csv`、`index_space_changes.csv`，也不再使用 `NO_BASELINE` 结论。空间项改为 `SPACE_WASTE_CANDIDATES`，只描述当前估算候选和覆盖范围。

`report.py` 只接受 v2.1 run，防止把旧的全量明细误当成新格式。已有 v2.0 run 请配套使用 [v2.0 的 report.py](https://github.com/0ch1nch1n/db_scripts/blob/40af038cabca2b9d48fd3bb35a8e66babc676af6/oracle/diagnostics/resource_check/report.py)。数据库和账号配置格式保持兼容。

一次快照不代表整月峰值；表浪费估算不等于实际可回收容量或确诊碎片率。完整判断规则见 [CHECK_RULES.md](CHECK_RULES.md)，离线验证与现场边界见 [VALIDATION.md](VALIDATION.md)。

## 来源

基于用户提供的 `Oracle_Resource_Check_v2.0.zip` 和已发布 v2.0 简化；原 ZIP 及实际配置留在本地，原发布版可从 Git 历史追溯。

- `source-manifest.json`：源 ZIP 哈希、原始文件哈希和 v2.1 改动/删除记录。
- `SHA256SUMS`：当前公开目录校验和，不含自身、运行输出和缓存。
- `original_sha256.json`：附件自带的更早六个文件历史哈希，对应文件未随包提供，不能视为已核验来源。
