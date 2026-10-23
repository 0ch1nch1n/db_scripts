# Oracle Health Check v3.1

[返回仓库首页](../../../README.md)

Oracle 19c 变更前后状态巡检工具。上传一个 Bash 文件到数据库服务器，在维护前保存基线，在维护后采集快照并比较，辅助判断本机数据库状态是否恢复。

`health_check_v3_1.sh` 和测试脚本沿用源仓库内容，本次整理没有修改巡检逻辑。

## 目录与来源

本目录于 2026-10-23 从 [0ch1nch1n/oracle-health-check](https://github.com/0ch1nch1n/oracle-health-check) 整理导入，来源提交为 [`19a77cf`](https://github.com/0ch1nch1n/oracle-health-check/commit/19a77cf41f0b38f4245182126050c6b5825f6339)。此处是该版本的副本，后续修改不会自动与源仓库同步。

| 文件 | 用途 |
| --- | --- |
| [health_check_v3_1.sh](health_check_v3_1.sh) | 单文件巡检工具；保留源文件内容和可执行权限 |
| [VALIDATION.md](VALIDATION.md) | 源仓库已有的验证记录，以及本次导入验证范围 |
| [tests/verify_health_check.py](tests/verify_health_check.py) | 语法、比较器及模拟 SQL*Plus 流程测试 |
| [.gitignore](.gitignore) | 本目录及其子目录的日志忽略规则 |

从 `db_scripts` 仓库根目录使用时，先进入此目录，再运行下文命令：

```bash
cd oracle/diagnostics/health_check
```

## 快速使用

要求：Bash 3.2+、Oracle 19c 的 SQL*Plus，以及常见 Unix 工具（`awk`、`sort`、`diff`、`ps`、`tee` 等）。运行脚本本身不需要 Python。使用具有本机 OS SYSDBA 认证权限的操作系统账户，例如已正确配置 OSDBA 组的 Oracle 软件所有者。

```bash
# 维护前：保存基线，CHANGE_ID 使用实际变更编号
bash health_check_v3_1.sh before CHG_20261019_001

# 维护后：在同一节点、同一日志根目录，使用同一变更编号
bash health_check_v3_1.sh after CHG_20261019_001

# 查看参数
bash health_check_v3_1.sh --help
```

默认日志目录为脚本旁的 `health_logs_v3/CHANGE_ID/`。同一个变更编号的基线不能覆盖；即使第一次 `before` 失败，已经生成的 `before/` 目录也会阻止重跑，排查后请使用新的变更编号。

## 工作流程

1. **确定实例范围**：`before` 默认从本机 `ora_pmon_SID` 进程发现实例，不包括 ASM 的 `asm_pmon_`。可通过 `DB_LIST` 手工指定范围。自动发现无法包含维护前就已经停止的实例。
2. **解析 Oracle Home**：自动模式先使用 `ORACLE_HOME_MAP` 或脚本顶部的 `ORACLE_HOME_OVERRIDES`；未指定时查询 `/etc/oratab`，必要时回退到 `/var/opt/oracle/oratab`。
3. **逐实例采集**：在独立 Bash 子进程中设置 SID、Home 及库路径，清除 `ORACLE_PDB_SID`、`TWO_TASK`、`LOCAL`，通过 `sqlplus -L -s '/ as sysdba'` 本机连接。
4. **检查容器**：先采集实例及数据库核心信息，再为可读容器读取数据字典。关闭或不可读的容器会标记 `SKIPPED`，不自动打开容器。
5. **冻结基线**：记录主机、SID 清单、采集结果。`after` 始终沿用基线 SID 清单，避免漏掉维护后没有启动的实例；自动模式还检查 PMON 的新增或缺失。
6. **生成报告**：快照按行排序，使用 AWK 进行语义比较，另保留原始 `diff` 证据。输出到终端及 `report.txt`。

## 检查哪些内容

| 类别 | 主要来源 | 内容 |
| --- | --- | --- |
| 数据库身份 | `v$database` | DBID、数据库名、唯一名、是否 CDB |
| 实例身份和状态 | `v$instance` | 实例名、主机、完整版本、状态、登录状态、启动时间 |
| 数据库状态 | `v$database` | OPEN_MODE、DATABASE_ROLE |
| PDB 状态 | `v$pdbs` | GUID、名称、打开模式、受限状态 |
| 本机服务 | `v$active_services` | 服务名、网络名、容器、是否阻塞 |
| PDB 插入错误 | `pdb_plug_in_violations` | ERROR 类型且 PENDING 的记录；仅根容器可读时查询 |
| 无效对象 | `dba_objects` | INVALID 对象，含 owner、类型、子对象及 edition |
| 数据库组件 | `dba_registry` | 组件版本及状态 |
| SQL 补丁历史 | `dba_registry_sqlpatch` | 补丁、动作、状态、版本及描述 |
| 本机 Oracle Home | Shell 环境解析 | 实际使用的 Oracle Home 路径 |

## 如何解读结果

| 退出码 | 含义 | 处理方式 |
| --- | --- | --- |
| `0` | 基线采集成功，或维护后没有新增问题 | 仍需阅读原有异常与业务验证结果 |
| `1` | 差异、警告或检查覆盖不足，需要复核 | 查看报告及每实例比较文件 |
| `2` | 采集不完整、快照无效、身份不匹配或运行错误 | 不能据此确认恢复 |

主要报告标记：

- `FAIL`：状态变化、新增无效对象、新增 PDB 错误等。版本、Oracle Home 等计划内变更也可能触发，需要结合变更单判断。
- `WARN`：服务或组件变化、补丁历史变化、容器字典检查被跳过等。RAC 服务迁移可能导致本机服务差异。
- `EXISTING`：原有无效对象、PDB 错误、非 VALID 组件或异常状态仍存在。这些项目本身不一定导致非零退出码。
- `RECOVERED`：在前后均有完整字典采集的容器内，原有无效对象减少；或 PDB 错误记录减少。
- `UNKNOWN`：无法完成可靠比较，例如 SQL*Plus 失败或实例身份不一致。

`NO_DIFFERENCES` 表示比较字段相同；`NO_NEW_ISSUES` 表示有基线问题减少。启动时间单独报告、排除在语义比较外，因此实例重启后仍可以返回 0。原始 `differences.diff` 仍可能包含启动时间变化。

## 可选配置

| 配置 | 用途 |
| --- | --- |
| `HEALTH_LOG_ROOT` | 指定日志根目录；前后必须指向同一位置 |
| `DB_LIST` | `before` 手工指定实例及可选 Home；`after` 使用冻结清单 |
| `ORACLE_HOME_MAP` | 自动发现模式的 SID/Home 映射文件 |
| `ORACLE_HOME_OVERRIDES` | 脚本顶部的多行 SID/Home 映射；未设置外部映射文件时生效 |
| `ORATAB` | 指定 oratab 路径；未明确提供 Home 时使用 |
| `SQLPLUS_TIMEOUT` | 每次 SQL*Plus 调用的超时秒数，默认 180，必须为正整数 |

手工清单示例（空行、整行注释允许；Home 路径不能包含空白或 `|`）：

```text
# SID [ORACLE_HOME]
ORCL /u01/app/oracle/product/19c/dbhome_1
TEST
```

```bash
DB_LIST=/secure/db_list.txt \
HEALTH_LOG_ROOT=/secure/oracle_health_logs \
bash health_check_v3_1.sh before CHG_20261019_002

HEALTH_LOG_ROOT=/secure/oracle_health_logs \
bash health_check_v3_1.sh after CHG_20261019_002
```

注意：手工 `DB_LIST` 模式直接采用清单中的 Home 或查询 oratab，**不会套用** `ORACLE_HOME_MAP` / `ORACLE_HOME_OVERRIDES`。`after` 会冻结显式提供的 Home；基线清单中未提供 Home 的实例则会重新查询当前 oratab，因此 Home 变更仍会被检测到。

## 输出文件

```text
health_logs_v3/CHANGE_ID/
├── before/
│   ├── manifest.txt              # SID|显式 Home，Home 可为空
│   ├── host / list_mode.txt
│   ├── complete                  # 全部实例可完成基线采集和验证
│   ├── report.txt
│   ├── SID.collector.log
│   └── SID/
│       ├── status / metadata.txt
│       ├── snapshot.dat
│       ├── core.sql / core.log
│       ├── dictionary_*.sql / dictionary_*.log
│       └── baseline_review.txt
└── after_YYYYMMDD_HHMMSS_PID/
    ├── manifest.txt / report.txt
    ├── complete                  # 完成本次比较；不代表结果一定通过
    └── SID/
        ├── snapshot.dat
        ├── comparison.txt
        └── differences.diff
```

还会根据发现模式保存 PMON 证据及缺失/新增清单。`complete` 是完成标记，不是健康证明。日志保留数据库名、主机名、对象名及补丁信息，应存放在受限目录，不要提交到代码仓库。本目录的 `.gitignore` 默认忽略其范围内的常见日志目录；使用外部日志路径或自行改名时，请另行确认忽略规则。

## 权限、影响及边界

- 脚本中的 SQL 是查询及会话设置，`alter session set container` 只切换当前会话容器；退出使用 rollback。没有数据库重启、对象编译、补丁安装或持久配置修改操作。
- 会写入本机文件，设置 `umask 077`，用目录锁防止同一变更编号并发运行。超时时会终止本次启动的 SQL*Plus 进程。
- SYSDBA 权限较高；应由受控账户执行。查询数据字典、传输结果会消耗资源，大量无效对象或补丁记录可能增加耗时和日志量。
- 不检查监听器、客户端连接、应用事务、备份、磁盘空间、ASM 或 Data Guard 复制延迟。RAC 仅覆盖当前节点，应在各节点分别执行并另外检查集群服务。
- MOUNTED 备库及关闭的 PDB 允许采集核心状态，但字典覆盖会不足。维护前如存在此情况，`before` 会在报告中提示，主流程仍可返回 0 并形成基线；维护后比较会要求复核，不能只看维护前退出码。
- 所有状态变化都需人工结合计划判断；本脚本没有“预期变更”白名单。
- 快照不是同一事务中的原子采集，采集期间发生的并发 DDL、服务迁移或 PDB 切换可能造成差异；建议在稳定窗口运行。
- PDB 错误使用整行记录比较：时间、描述等字段变化也可能被视为旧记录消失、新记录出现。某些 `RECOVERED` 记录需结合容器范围及实际状态复核。
- 意外中断可能留下 `.lock`。仅在确认没有相关巡检进程仍在运行后，才手工处理遗留锁。

## 验证范围

参见 [VALIDATION.md](VALIDATION.md)。其中的 26 项通过结果为源仓库已有记录，本次导入未重新运行测试，也未连接 Oracle 实例。语法、比较器及模拟流程的检查不能代替真实数据库验证。
