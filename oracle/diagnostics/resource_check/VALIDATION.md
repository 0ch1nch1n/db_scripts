# 发布验证记录：v2.1

验证日期：2026-11-03（Asia/Shanghai）。环境：Apple Silicon macOS、Bash 5.3.20（Homebrew）、Python 3.9.6。没有连接真实 Oracle。

## 检查与结果

| 检查 | 结果 |
| --- | --- |
| Bash 语法检查 | 通过 |
| Python 编译检查 | `report.py`、两个测试模块通过 |
| 离线测试 | 30/30 通过：8 项采集流程、15 项报表、7 项实际 SQL 文本的模拟字典测试 |
| 模块与格式 | 默认 7 个模块，不调用 `index_space`；run 版本为 2.1；拒绝 `--baseline` 和 v2.0 run |
| 公开内容 | 通用配置保持；不提交实际配置、运行结果和缓存；来源清单及校验和已更新 |

## 复现

在本目录中，确保 PATH 中的 `bash` 为 4+：

```bash
bash -n check_resources.sh
python3 -m py_compile report.py tests/test_workflow.py tests/test_compact_sql.py
python3 -m unittest discover -s tests -v
```

本次 Mac 使用：

```bash
env PATH=/opt/homebrew/bin:$PATH PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -m unittest discover -s tests -v
/opt/homebrew/bin/bash -n check_resources.sh
```

测试中的 `oraenv` 和 `sqlplus` 为临时模拟程序，只处理通用测试配置，不连接数据库。

## 覆盖

- SP2 stdout/stderr 零退出码错误、静默非零退出码、SID 重试、失败模块后继续、相对输出目录、只采集模式。
- 参数注入与重复标签提前拒绝；MB/百分比阈值传入 SQL*Plus；正常流程恰好 7 个成功模块。
- 正常对象计数恢复、异常身份保留、重叠异常不重复计入待复核总数、锁定统计、不可用索引。
- 空范围、未配置账号、缺失和即将到期账号；坏 CSV、非法数量、重复压缩行和不可靠/未超阈值候选均不报正常。
- 1000 个正常表在实际 SQL 文本执行后输出为 1 条正常计数；系统用户被过滤。
- 临时表 SHARED/SESSION 统计身份独立保留，空间表数不重复；缺失/过期/未知/锁定统计和分区异常保留；不可用索引及其分区/子分区保留状态。
- 分区/压缩/特殊表、不可靠统计、缺少段和缺少输入保留数量；两个候选阈值均为严格大于。
- 直接执行本版 SQL 文本的输出可送入本版报表，统计数量和候选保持一致。

`test_compact_sql.py` 将实际 SQL 的查询部分在 SQLite 内存字典上执行，适配 NVL、TO_CHAR、CEIL、POWER、GREATEST 等标量函数。它验证分组、筛选和报表接口；不能代替 Oracle SQL 编译、真实视图、执行计划或 SQL*Plus 替换变量验证。

## 来源与改动

基于 v2.0 发布提交 `40af038cabca2b9d48fd3bb35a8e66babc676af6`。原 ZIP 不改动、不公开上传。

v2.1 修改 Shell、Python、三个统计/空间 SQL、测试及说明；移除独立 `sql/index_space.sql`，由 Git 历史保留。表空间、UNDO、账号和身份采集 SQL 及公共 include 没有改动。`source-manifest.json` 记录每个源文件当前状态，`SHA256SUMS` 覆盖当前公开目录。

## 首次现场检查

仍需验证真实 Oracle 19c/RU 的 SQL 视图、列名、权限、容器可见性、RAC/local/shared UNDO 和 non-CDB/TEMP 口径；SQL*Plus 第 9/10 参数的空间阈值传递也须现场确认。没有实际执行计划、负载或性能改善测量。

先在低峰期配置一库，确认 `execution_status.csv` 中 7 个模块最终成功、`report_errors.csv` 没有错误；核对统计汇总与明细、空间候选及跳过数量，再扩大范围。退出码 0 后仍需阅读月报的 `ALERT` 和 `REVIEW`。
