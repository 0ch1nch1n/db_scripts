# Redshift 角色权限 CSV 盘点

在能够访问 Redshift endpoint 的电脑或服务器上运行 Python 脚本。SQL 客户端（例如 DBeaver、DataGrip、Query Editor）不能直接执行这个 Python 文件；要在终端或 PowerShell 执行。

脚本只向 Redshift 发送 SELECT，不修改用户、角色、授权或数据库对象。使用 AWS 官方 `redshift-connector`，通过 SSL 校验证书和 endpoint 主机名。当前版本使用数据库用户名和密码；不自动复用 SQL 客户端的 SSO/IAM 登录。

## 一、准备

- 推荐 Python 3.10 或更新版本；脚本语法兼容 Python 3.9。驱动的实际 Python 要求以安装版本为准。
- 确认目标数据库名。如果 `redshiftdb` 只是你对 Redshift 的称呼，运行时填真实数据库名。
- 准备 endpoint、端口（常见为 5439，按实际配置）、数据库用户名、密码。
- 运行机器必须能访问 endpoint 和数据库端口；私有集群通常需要公司网络、VPN 或 VPC 内服务器。
- 建议使用现有 superuser 账号做完整盘点。普通账号可能只看到部分数据；本脚本不会修改账号权限。
- 首次安装依赖需要访问 Python 包源；受限环境可使用公司允许的镜像或离线依赖包。

## 二、macOS / Linux

将本仓库克隆或下载到能够访问 Redshift 的执行机器。进入脚本目录，例如：

```bash
cd db_scripts/redshift/security/role_permission_audit
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
```

上面是首次准备；之后每次盘点执行下面一条命令，将示例主机和用户名替换为实际值：

```bash
.venv/bin/python export_redshift_permissions.py \
  --host 'your-cluster.xxxxxx.ap-northeast-1.redshift.amazonaws.com' \
  --port 5439 \
  --database 'redshiftdb' \
  --user 'your_audit_user'
```

出现 `Redshift password (hidden):` 时输入数据库密码并按回车。密码输入时不显示，也不需要写入脚本或命令参数。默认输出到脚本所在文件夹的 `exports/audit_UTC时间/`，末尾会打印绝对路径。

## 三、Windows PowerShell

例如将文件夹放在 `C:\DBA\db_scripts\redshift\security\role_permission_audit`：

```powershell
cd 'C:\DBA\db_scripts\redshift\security\role_permission_audit'
py -3 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
```

执行（下方用一行命令，避免 PowerShell 换行符混用）：

```powershell
.\.venv\Scripts\python.exe export_redshift_permissions.py --host 'your-cluster.xxxxxx.ap-northeast-1.redshift.amazonaws.com' --port 5439 --database 'redshiftdb' --user 'your_audit_user'
```

如果找不到 `py`，先确认已安装 Python；可用 `python --version` 检查，存在时把上面的 `py -3` 换成 `python`。

## 四、先看哪些 CSV

| 文件 | 内容 |
| --- | --- |
| `10_roles.csv` | 全部可见角色及其 owner、external_id 等原始字段 |
| `11_users.csv` | 全部可见用户，包含 superuser 标志；不导出密码字段 |
| `user_roles_direct.csv` | 每个用户直接获得的角色，包含 admin_option；无直接角色的用户保留空行 |
| `user_roles_expanded.csv` | 直接和间接获得的角色；保留起始 direct_role_name 和最短 inheritance_depth |
| `role_permissions_direct.csv` | 角色直接授权的合并清单 |
| `role_permissions.csv` | 角色直接及继承权限；source_role_name 表示权限来自哪个角色 |
| `export_status.csv` | 每项导出是否成功、行数和错误原因 |
| `manifest.json` | 连接目标、开始结束时间、范围、可见性提示和模块状态；不保存密码 |

`user_roles_expanded.csv`：depth=0 为直接角色，depth>0 为继承角色。同一个角色可能通过多个直接角色获得，因此可有多行。`NO_EXPLICIT_ROLE` 仅表示未查到直接角色，不能据此判断用户没有权限。

`role_permissions.csv`：depth=0 为角色自身的直接授权，depth>0 为从 source_role_name 继承。这个文件合并数据库、Schema、表/视图、列、函数、系统、默认、IAM、语言、Datashare、ML 模型授权。按 `role_name` 筛选即可查看某个角色。

`privilege_scope` 保留原值；例如 TABLES / FUNCTIONS 是范围授权。`details_json` 保留来源记录全部字段，包括函数参数等不会在统一列完整展开的信息。默认权限保留在 `default_privileges` 类别，是新建对象规则，不能当作已有对象权限。

另外，`30_*.csv` 到 `40_*.csv` 是各权限视图的原始导出，包含所有可见 identity 类型（role/user/group/public），用于补充核对用户直接授权和 PUBLIC。两个合并 role 权限文件仅保留 role。

CSV 使用 UTF-8 BOM，包含表头，逗号、引号和换行会正确转义。SQL NULL 导出为空字段；如需区分 NULL 与空字符串，可核对保存的 SQL 和源视图。Excel 导入时建议选择“数据 → 从文本/CSV”，将名称/ID 字段设为文本，避免自动转换。

## 五、如何判断执行成功

- `Status: complete` 且退出码为 0：本版本列出的源查询和派生报告均完成，并确认连接账号的 pg_user.usesuper 为 true。这不代表完整有效权限评估或覆盖未来新增的所有 Redshift 功能。
- `Status: partial_or_visibility_unverified` 且退出码为 2：至少一个模块失败，或未确认 superuser 可见性。检查 `export_status.csv` 和 `manifest.json`；不要把结果当作完整清单。某些受委派管理员实际可能有足够可见性，脚本仍保守标记为未验证。
- 退出码 1：连接、依赖或运行失败。若已创建输出目录，错误记在 `manifest.json`。
- 中断退出码 130：结果不完整，manifest 标为 interrupted。
- 成功查询但无授权时，CSV 仍有表头且行数为 0。失败查询没有正常 CSV，若留下 `.csv.part`，它只是中断写入的未完成文件。
- 某权限视图不存在或无权访问时，脚本会继续导出其他模块，并明确报告 partial；合并权限文件只覆盖成功模块。若角色关系来源失败，不生成继承展开报告。

macOS/Linux 可在执行后立即用 `echo $?` 看退出码；PowerShell 用 `$LASTEXITCODE`。

## 六、其他用法

指定新的输出目录（不能已存在，避免覆盖上次结果）：

```bash
.venv/bin/python export_redshift_permissions.py --host 'your-endpoint' --database 'redshiftdb' --user 'your_user' --out './exports/manual_audit_01'
```

不安装驱动、不连接数据库，只查看脚本使用的 SQL：

```bash
python3 export_redshift_permissions.py --print-sql
```

包内的 `queries.sql` 是同一份 SQL，可在 SQL 客户端逐条核对。用户/角色继承展开和统一 CSV 合并由 Python 完成，所以 `queries.sql` 本身不负责自动导出 CSV。

计划任务可通过企业现有密钥管理机制注入环境变量 `REDSHIFT_PASSWORD`；脚本会优先读取该变量。不要把密码放入命令行、共享文件、版本库或日志。当前脚本不实现 IAM/SSO 登录；仅有 IAM/SSO 的环境需要先调整认证方式。

## 七、范围和限制

- 角色/用户关系是集群或 namespace 范围；Schema、表、列、函数等本地对象视图以本次连接数据库为范围。盘点多个业务库需要分别运行；数据库级视图可能列出其他数据库，不能由此推断其他库对象权限已采集。
- 导出是依次查询，不是同一时刻的原子快照。盘点期间若有授权变更，结果可能不一致；优先选择权限变更较少的时间执行。
- 角色继承在本地展开，含防循环保护，避免数据库递归查询膨胀；只反映本次采集到的显式授予关系。
- 不计算 superuser/对象 owner 的隐含权限，不展开旧式 group 成员，不评估 RLS/DDM 策略或临时联邦登录的会话角色。用户完整实际权限需要结合这些因素和 raw 文件中的 user/PUBLIC 授权判断。
- 这里是常见本地授权的批量 CSV 盘点；外部 catalog、datashare、联邦权限或新对象类型需要再用 SHOW GRANTS/相应元数据补查。AWS 推荐 SHOW GRANTS 进行权限发现。

## 八、本地验证

```bash
python3 -m unittest discover -s tests -v
```

测试使用模拟数据库结果，检查 CSV 转义、角色继承方向、循环/最短路径、普通账号可见性提示和模块失败处理。没有 Redshift 连接信息时，不代表已在目标数据库验证 SQL 或网络/认证。

本次验证记录见 [VALIDATION.md](VALIDATION.md)。测试文件位于 [tests/test_export.py](tests/test_export.py)。

官方参考：

- https://github.com/aws/amazon-redshift-python-driver
- https://docs.aws.amazon.com/redshift/latest/mgmt/python-configuration-options.html
- https://docs.aws.amazon.com/redshift/latest/dg/r_SVV_USER_GRANTS.html
- https://docs.aws.amazon.com/redshift/latest/dg/r_SVV_ROLE_GRANTS.html
- https://docs.aws.amazon.com/redshift/latest/dg/r_SHOW_GRANTS.html
