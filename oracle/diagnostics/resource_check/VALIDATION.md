# 发布验证记录

验证日期：2026-11-03（Asia/Shanghai）。范围：离线采集流程、报表逻辑、来源完整性和公开发布内容；没有连接真实 Oracle。

## 环境与结果

验证环境为 Apple Silicon macOS，Bash 5.3.20（Homebrew）、Python 3.9.6（系统 Python）。Mac 原有 `/bin/bash` 为 3.2，本次另行安装 Homebrew Bash 以满足脚本要求，未更改登录 Shell。

| 检查 | 结果 |
| --- | --- |
| 原 ZIP 内的 `SHA256SUMS` | 所有列出的原文件均匹配 |
| 发布代码与附件比较 | `check_resources.sh`、`report.py`、9 个 SQL 文件和测试文件共 12 个文件字节一致 |
| Bash 语法检查 | 通过 |
| Python 编译检查 | `report.py` 和 `tests/test_workflow.py` 通过 |
| 原有离线测试 | 18/18 通过：6 项采集流程、12 项报表逻辑；运行耗时约 2.7 秒 |

## 复现命令

在本工具目录中，确保 PATH 中的 `bash` 为 4+ 后执行：

```bash
bash --version
bash -n check_resources.sh
python3 -m py_compile report.py tests/test_workflow.py
python3 -m unittest discover -s tests -v
```

本次 Mac 的测试命令为：

```bash
env PATH=/opt/homebrew/bin:$PATH /usr/bin/python3 -m unittest discover -s tests -v
/opt/homebrew/bin/bash -n check_resources.sh
```

Python 编译使用工作目录中的 `PYTHONPYCACHEPREFIX`，避免写入受限的系统缓存。测试内的 `oraenv` 和 `sqlplus` 均为临时模拟程序；不调用真实 Oracle 客户端，不连接数据库，不使用附件中的数据库清单。临时目录在测试后清理。

## 测试覆盖

- SQL*Plus 返回 0 但 stdout/stderr 出现 SP2 错误时判失败；失败 SID 重试。
- 静默非零返回码不判成功，单模块失败后继续后续模块。
- `--collect-only` 不生成报表，相对输出目录可用。
- 配置注入和重复数据库标签在采集前拒绝。
- 无基线、未来/自身基线、数据库身份变化、对象重建、对象移出范围、过期统计信息。
- 功能账号预期锁定、缺失账号、即将到期，未配置账号范围保持待复核。
- 失败模块及坏 CSV 不产生正常结论；统计锁定列为待复核。
- 表浪费候选使用严格阈值；CSV 逗号和引号可正确转义。

## 公开版整理

- 实际数据库标签、SID、DB_NAME 和 PDB 映射替换为通用示例；文档和账号示例同步脱敏。
- 新增中文仓库说明、验证记录、运行输出及本地配置忽略规则。
- 重新生成公开目录 `SHA256SUMS`，并用 `source-manifest.json` 区分原始文件、脱敏/文档修改和新增文件。
- `original_sha256.json` 中更早六个文件未随 ZIP 提供，仅保留历史记录，不能视为本次已核验来源。

## 验证边界与首次现场检查

离线测试模拟了 SQL 输出，不能验证 SQL 的视图、列名、权限、容器可见性及计算结果。SQL 尚未在实际 Oracle 19c/RU/SQL*Plus 环境编译执行；RAC、local/shared UNDO、non-CDB、TEMP 容量汇总与特殊对象覆盖均需现场核对。

部署前先配置单个数据库及真实功能账号，核对 `execution_status.csv` 中 8 个模块的最终状态，检查逐库 CSV、错误日志、`report_errors.csv` 和月报结论。确认后再扩大采集范围。退出码 0 仅代表执行完成；需要另行阅读 `ALERT`、`REVIEW` 和 `NO_BASELINE`。

一次快照、空间估算和账号元数据各有范围限制，详见 [CHECK_RULES.md](CHECK_RULES.md)。
