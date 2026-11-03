# Oracle Resource Check v2.0

Oracle 月度资源巡检工具：在数据库主机上通过本机 OS SYSDBA 认证采集数据，再用 Python 生成逐库汇总和可复核明细。

## 检查内容

| 项目 | 实际行为与判断口径 |
| --- | --- |
| 表空间 / UNDO | 永久、TEMP、UNDO 容量与使用情况；默认当前容量口径严格 `>90%` 告警；UNDO 为各可见实例最近采样桶 |
| 表 / 索引统计信息 | 采集表、索引及分区/子分区的分析时间、过期状态、统计锁定与索引状态 |
| 空间变化复核 | 对支持的普通堆表估算浪费，保存完整顶层表清单；显式指定历史 run 后比较表估算与索引结构变化 |
| 功能账号 | 按显式账号清单检查预期状态、到期窗口和认证类型；未配置清单时返回 `REVIEW` |

Shell 调用 `oraenv` 和 SQL*Plus；8 个采集模块分别尝试配置中的本地 SID，失败后可尝试下一 SID，记录每次结果。Python 仅处理已采集 CSV，不连接数据库。

## 环境与影响

- 目标数据库：Oracle Database 19c；实际 RU、CDB/PDB、RAC 和 non-CDB 的 SQL 兼容性仍需现场验证。
- 采集主机：Bash 4+、可在 PATH 中找到的 `oraenv`、SQL*Plus 12.2+（建议 19c），以及能够执行 `/ as sysdba` 的操作系统账号。
- 报表：Python 3.8+，仅标准库，无第三方依赖；可在 Mac 或其他主机离线生成。
- 数据库操作为字典/动态视图查询及会话级容器、数值格式和时区设置；不执行统计信息收集、账号修改、SHRINK、MOVE、REBUILD 或 Advisor 任务。
- 在本地创建运行目录、明细、日志和报表；大库上的字典查询成本需先单库评估。
- RAC 的 SID 列表表示当前主机可尝试的实例，不会通过 SSH 或服务名跨节点连接。UNDO 使用可见 `GV$` 数据。

## 首次使用

公开仓库中的 `db_list.conf` 仅是示例，原附件中的实际数据库映射未上传。

```bash
cp db_list.conf db_list.local.conf
cp functional_accounts.csv functional_accounts.local.csv
```

先编辑这两份本地文件，再执行：

```bash
bash check_resources.sh --db-list db_list.local.conf --accounts functional_accounts.local.csv
```

数据库清单每行格式如下；前四列需要保留，PDB 可以留空，第五列可选：

```text
# database_label|local_sid1/local_sid2|expected_db_name|pdb|optional_expected_db_unique_name
APP_PDB|ORCL1/ORCL2|ORCL|APPPDB|ORCL_PRIMARY
```

脚本会核对 `DB_NAME`、可选的 `DB_UNIQUE_NAME` 和目标 PDB。PDB 留空时，CDB 仅检查 root，non-CDB 检查该库，不会遍历全部 PDB。建议首次只配置一个数据库。

功能账号格式见 [functional_accounts.example.csv](functional_accounts.example.csv)。默认 `functional_accounts.csv` 只有表头，不猜测业务账号范围；账号有效性不等于已测试应用登录。

`*.local.conf`、`*.local.csv` 和默认 `output/` 已加入本目录 `.gitignore`。实际配置及采集结果应留在本地；自定义输出路径应放在仓库外。

## 采集与报表分开执行

数据库主机没有 Python 时：

```bash
bash check_resources.sh --db-list db_list.local.conf --accounts functional_accounts.local.csv --collect-only
```

将整个生成的 run 目录和 `report.py` 复制到 Python 主机后执行：

```bash
python3 report.py /path/to/collected_run_directory
```

后续可显式指定更早的 v2 run 目录作为基线：

```bash
bash check_resources.sh --db-list db_list.local.conf --accounts functional_accounts.local.csv --baseline /path/to/previous_run_directory
```

也可仅重新生成报表：

```bash
python3 report.py /path/to/current_run_directory --baseline /path/to/previous_run_directory
```

基线必须比当前 run 更早，数据库/容器身份需一致；对象 ID、数据对象 ID 或 DDL 时间变化会单独标记。重新运行报表会重写当前 run 的派生报表，保留采集明细和日志。

## 参数

| 参数 | 默认值 / 用途 |
| --- | --- |
| `--db-list FILE` | `db_list.conf`；数据库映射 |
| `--accounts FILE` | `functional_accounts.csv`；显式功能账号清单 |
| `--output DIR` | `output/`；每次新建 `run_时间戳_随机后缀/` |
| `--baseline RUN_DIR` | 无；显式指定更早 v2 run |
| `--threshold NUMBER` | `90`；使用率严格大于阈值 |
| `--basis CURRENT\|MAX` | `CURRENT`；当前容量或配置最大容量口径 |
| `--waste-mb NUMBER` | `100`；表估算候选严格大于该 MB 值 |
| `--waste-pct NUMBER` | `30`；候选还必须严格大于该百分比 |
| `--expiry-days INTEGER` | `30`；到期提醒窗口，可由账号行覆盖 |
| `--collect-only` | 仅采集，稍后生成报表 |
| `--help` | 查看完整帮助 |

## 结果与退出码

先查看 `monthly_summary.csv`、`monthly_summary.md` 和 `execution_status.csv`，再查看逐库明细和 `logs/`。其余派生文件包括统计汇总、表浪费候选、表/索引变化、账号复核和报表错误记录。

- `0`：执行完成，仍可能存在 `ALERT`、`REVIEW` 或 `NO_BASELINE`。
- `1`：采集或报表失败，查看执行状态和日志。
- `2`：参数、配置或依赖错误。

一次采集代表一个时间快照，不代表整月峰值。表空间 MAX 是文件配置上限，没有检查 ASM/文件系统余量。表浪费是粗略估算，不等于可回收容量；索引结构变化不等于碎片率，也不会自动给出重建建议。完整规则和原有 Oracle 官方参考见 [CHECK_RULES.md](CHECK_RULES.md)。

## 验证与来源

发布前重新执行的检查、测试命令和限制见 [VALIDATION.md](VALIDATION.md)。离线验证不代表 SQL 已在真实 Oracle 环境通过。

来源为用户提供的 `Oracle_Resource_Check_v2.0.zip`。Shell、Python、9 个 SQL 文件（含公共 include）和原有 18 项测试保持字节一致；公开配置替换为通用示例，说明文档按仓库使用方式整理。原 ZIP 保留在本地，未作为公开附件上传。

- `source-manifest.json`：当前 ZIP 的 SHA-256、每个原始文件的哈希及公开版改动说明。
- `SHA256SUMS`：当前公开目录的逐文件校验和，不含该校验和文件自身、运行结果与缓存。
- `original_sha256.json`：附件内自带的更早六个文件的历史哈希，本次没有对应原文件可核验。
