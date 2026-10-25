# 验证记录

日期：2026-10-25。

## 本地验证

在 macOS、Python 3.9.6 下运行：

```bash
python3 -m unittest discover -s tests -v
python3 export_redshift_permissions.py --help
python3 export_redshift_permissions.py --print-sql
```

9 项模拟数据测试通过，覆盖：

- UTF-8 BOM、中文、逗号、引号和换行的 CSV 往返读写，以及空结果保留表头。
- 中断写入仅保留 .part，避免把半成品发布为正常 CSV。
- 角色继承方向、最短继承距离和循环保护。
- 用户直接/间接角色、无直接角色用户保留，以及默认权限 grantee 字段处理。
- 原始权限文件保留 user/PUBLIC，角色合并报告只包含 role。
- 权限查询失败后继续其他模块，并明确标记结果不完整。
- 角色关系来源失败时不生成继承展开报告。
- 普通用户可见性未确认时，不将运行标记为 complete。
- 系统级授权不错误标注为当前数据库的对象授权。
- 收集 SQL 均为 SELECT；--print-sql 不依赖驱动或数据库连接。

`queries.sql` 已与脚本 --print-sql 的输出核对一致。

## 尚未验证

未连接实际 Redshift 实例，未验证目标网络、SSL/认证、各视图在目标版本的可用性及账号可见性。
依赖声明为 redshift-connector>=2.1,<3，未锁定完整依赖树；请在执行环境安装并记录实际版本。
收录不代表已在生产环境验证。首次运行请检查 export_status.csv、manifest.json 及采集范围。
