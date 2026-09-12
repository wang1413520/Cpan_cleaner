# 变更日志

本项目遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

---

## [1.0.0] - 2026-09-12

首个公开版本。

### 新增

**扫描与分级**
- `Scan-CDrive.ps1` —— 遍历指定盘，把目录分为六类判定：
  `DELETE` 可删 / `MIGRATE` 可迁 / `REDIRECT` 重定向 / `REVIEW` 待定 / `ALREADY` 已迁 / `BLOCK` 禁区
- 基于确定性规则：路径黑名单、重解析点类型、目录名模式、扩展名分布、占用检测、SQLite 活动标记
- 输出 JSON / CSV / 纯路径清单

**AI 标注（可选）**
- `Annotate-CDriveReport.ps1` —— 把 `REVIEW` 目录的脱敏元数据发给大模型识别用途
- 支持 OpenAI 兼容接口与 Anthropic 接口，也支持本地 Ollama
- 本地缓存（按 `路径+体积+判定` 做 SHA256），重复运行不重复计费
- **AI 只有否决权，没有批准权** —— 规则判 `BLOCK` 的目录绝不外发；AI 无法把判定升级为更激进的操作
- 设置持久化：端点/模型明文保存，**API Key 用 Windows DPAPI 加密**

**迁移**
- `MigrateCore.psm1` —— 13 项预检 + 复制校验 + 原子切换 + 四层回滚
  - 复制阶段绝不碰源目录
  - 校验通过前绝不删源
  - 用「重命名」代替「删除」做切换，把风险窗口压缩到毫秒级
  - 回滚自动选代价最低的方案（A 重命名 / B 补链接 / C 完整搬回 / D 清理孤儿）
- `Invoke-MigrationQueue.ps1` —— 队列执行器，逐项独立预检，单项失败不中断队列

**清理**
- `Clean-CDriveItems.ps1` —— 只对判定为 `DELETE` 的目录生效
- 四层安全闸门：判定过滤 → 强制预览 → 执行器独立再过滤 → 硬禁区 + 链接安全
- 支持「移入回收站」（可恢复）与「永久删除」两种模式

**图形界面**
- `MigrateGui.ps1` —— 四个标签页：扫描 / AI 标注 / 决策清单 / 执行迁移
- 零依赖 WinForms，界面与逻辑分离，后台独立进程执行不卡界面
- 实时日志流式回显、进度上报、结果表、F5 刷新

**测试**
- `Run-Acceptance.ps1` —— 15 条验收 / 58 项断言，全部在临时目录上跑
- 覆盖：预检失败、复制中断、校验不一致、`mklink` 失败、清理失败、
  中文与空格路径、四种回滚方案、清理安全闸门、链接安全

**工具**
- `Repair-Annotation-Encoding.ps1` —— 标注结果编码乱码还原

**文档**
- `README.md` —— 含界面预览截图、下载直链、安全模型摘要、折叠式 FAQ
- `docs/使用教程.md` —— 从下载到迁移完成的分步图文教程
- `docs/安全设计.md` —— 完整安全模型说明
- `docs/常见问题.md` —— 30+ 条 FAQ
- `docs/images/` —— 7 张界面截图

### 修复（开发过程中发现并修复的实现缺陷，均已补验收断言）

- `Start-Process -PassThru` 不加 `-Wait` 时读不到 `ExitCode`，导致所有迁移误判失败 → 改用 `ProcessStartInfo` + `Process.Start`
- 把「是否管理员」当硬门槛 —— 但 NTFS 上创建 Junction **不需要管理员** → 改为直接探测真实能力
- 强杀 robocopy 返回负值，原实现只判 `>= 8` → 会被当成成功 → 加固为 `>=8 或 <0 或读不到` 一律失败
- 回滚方案 A 不清理已复制到目标的副本 → 新增方案 D 检测与清理
- 方案 D 删除前无安全校验 → 增加与 manifest 记录比对，不符即拒绝
- 清理执行器把 `C:\Users` 当子树封锁 → 导致用户目录下所有缓存都无法清理 → 改为只精确拦用户主目录
- PowerShell 5.1 的 `Invoke-RestMethod` 在服务端不带 `charset` 时按 ISO-8859-1 解码 → 中文乱码 → 改为自行按 UTF-8 解码
- WinForms `Anchor` 在容器尺寸确定前设置导致控件位置全部错位 → 记录设计尺寸，窗体显示后重设
- `FormClosing` 里把 `break` 放进了 `ForEach-Object` 脚本块 —— 抛 `BreakException`，`try/catch` 抓不住，会弹出 .NET 未处理异常框 → 改用 `for` 语句，并加全局异常安全网
- 决策清单右上角状态栏文字过长被截断 → 改为紧凑格式
- 「AI建议」列直接显示 `keep/review/delete/migrate` 英文枚举 → 汉化为「别动/待定/可删/可迁」
