# Cpan_cleaner · C 盘迁移助手

> 把 C 盘上的目录**物理迁移**到其他盘，并在原位置建立目录联接（Junction），
> 使原程序**路径不变、无感知、照常启动**。

![Platform](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-0078D6?logo=windows)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell)
![Dependencies](https://img.shields.io/badge/dependencies-zero-brightgreen)
![License](https://img.shields.io/badge/license-MIT-green)

**零依赖** · **无需管理员** · **任何失败都不会破坏源目录** · **三层回滚**

---

## 目录

- [它解决什么问题](#它解决什么问题)
- [下载](#下载)
- [快速开始](#快速开始)
- [四步工作流](#四步工作流)
- [安全模型](#安全模型)
- [命令接口](#命令接口)
- [常见问题](#常见问题)
- [项目结构](#项目结构)
- [技术细节](#技术细节)
- [许可证](#许可证)

---

## 它解决什么问题

C 盘满了，但**不敢乱删**——怕删掉某个软件的数据。

常规做法是「卸载重装到 D 盘」，但很多软件：

- 没有自定义安装路径的选项
- 重装要重新登录、重新配置
- 有些数据目录根本不会跟着安装路径走

**本工具的思路**：把整个目录搬到 D 盘，然后在原位置放一个"传送门"（Junction）。
程序访问 `C:\...\某目录` 时，Windows 自动重定向到 `D:\...\某目录`。
**程序完全感知不到，路径没变，什么都不用重装。**

```
迁移前:  C:\Users\me\AppData\Local\某软件\  ← 真数据（2 GB，全在 C 盘）
迁移后:  C:\Users\me\AppData\Local\某软件\  → Junction →  D:\moved\某软件\  ← 真数据
         （程序照常访问这个路径，实际读到的是 D 盘）
```

---

## 下载

### 方式 1：下载 ZIP（推荐，最简单）

**👉 [点此下载最新版 ZIP](https://github.com/wang1413520/Cpan_cleaner/archive/refs/heads/main.zip)**

下载后解压到任意目录（例如 `D:\Cpan_cleaner`），双击 `启动-C盘迁移助手.cmd` 即可。

### 方式 2：git clone

```bash
git clone https://github.com/wang1413520/Cpan_cleaner.git
cd Cpan_cleaner
```

### 方式 3：只要界面脚本

不想 clone 整个仓库的话，直接下载这几个文件放到同一个目录：

| 必需 | 文件 |
|---|---|
| ✅ | [`MigrateGui.ps1`](https://raw.githubusercontent.com/wang1413520/Cpan_cleaner/main/MigrateGui.ps1) — 图形界面 |
| ✅ | [`MigrateCore.psm1`](https://raw.githubusercontent.com/wang1413520/Cpan_cleaner/main/MigrateCore.psm1) — 迁移核心 |
| ✅ | [`Scan-CDrive.ps1`](https://raw.githubusercontent.com/wang1413520/Cpan_cleaner/main/Scan-CDrive.ps1) — 扫描分级 |
| ✅ | [`Annotate-CDriveReport.ps1`](https://raw.githubusercontent.com/wang1413520/Cpan_cleaner/main/Annotate-CDriveReport.ps1) — AI 标注 |
| ✅ | [`Invoke-MigrationQueue.ps1`](https://raw.githubusercontent.com/wang1413520/Cpan_cleaner/main/Invoke-MigrationQueue.ps1) — 迁移执行器 |
| ✅ | [`Clean-CDriveItems.ps1`](https://raw.githubusercontent.com/wang1413520/Cpan_cleaner/main/Clean-CDriveItems.ps1) — 清理执行器 |

> 也可到 [Releases](https://github.com/wang1413520/Cpan_cleaner/releases) 页面查看版本化下载。

### 系统要求

| 项目 | 要求 |
|---|---|
| 系统 | Windows 10 / 11 |
| PowerShell | 5.1（系统自带，无需安装） |
| 文件系统 | NTFS |
| 权限 | **不需要管理员**（NTFS 上创建 Junction 无需提权） |
| 依赖 | **无**。不装模块、不装包、不联网也能跑 |

---

## 快速开始

1. 双击 **`启动-C盘迁移助手.cmd`**
2. 切到「**1. 扫描**」→ 点「开始扫描」（约 1–3 分钟）
3. 切到「**3. 决策清单**」→ 看扫描结果
4. 勾选「**可迁 MIGRATE**」的目录 → 切到「**4. 执行迁移**」
5. 填目标盘父目录（如 `D:\moved`）→「① 载入勾选项」→「② 仅预检」→「③ 开始执行」

出问题随时点「**回滚上次执行**」。

---

## 四步工作流

### 1. 扫描

遍历指定盘，把每个目录分为**六类**：

| 判定 | 含义 | 建议动作 |
|---|---|---|
| 🟢 `ALREADY` **已迁** | 已经是链接 | 无需处理 |
| 🔴 `DELETE` **可删** | 缓存 / 临时 / 日志 / 安装包残留 | **清理**，不要迁移 |
| 🔵 `MIGRATE` **可迁** | 应用数据目录 | 用本工具迁移 |
| 🟠 `REDIRECT` **重定向** | 桌面 / 文档 / 下载 | 用系统「属性 → 位置 → 移动」 |
| ⚪ `REVIEW` **待定** | 规则无法定性 | 交给 AI 标注或人工判断 |
| ⛔ `BLOCK` **禁区** | 系统目录 / 驱动 / 云同步占位 | **绝对不碰** |

判定依据是确定性规则：路径黑名单、重解析点类型、目录名模式、扩展名分布、
占用检测、SQLite 活动标记、体积门槛。

### 2. AI 标注（可选）

把 `REVIEW` 目录的**脱敏元数据**发给大模型，让它识别「这个目录是什么」。

```
回收站                    →  回收站内为已删除文件，清空即释放空间
MinGW-w64 编译工具链       →  根目录工具链，PATH 与 IDE 记录绝对路径，迁移风险高
Codex CLI 数据目录         →  含 SQLite WAL 且有文件被占用，迁移易损坏数据库
```

- 设置**持久化**：端点/模型明文保存，**API Key 用 Windows DPAPI 加密**
- 支持 OpenAI 兼容接口与 Anthropic 接口，也支持本地 Ollama（完全离线）
- **AI 只有否决权，没有批准权**（见下）
- 不配置也能用——规则引擎本身已给出完整判定

### 3. 决策清单

三色清单，每行显示绝对路径、体积、AI 识别的「是什么」、建议、依据。

- **导出清单** —— 生成 JSON / CSV / 纯路径清单
- **刷新状态**（或按 **F5**）—— 重新读取磁盘当前状态，已迁移的自动归入「已迁」
- **清理勾选项** —— 清理判定为 `DELETE` 的目录

### 4. 执行迁移 / 清理

**迁移**：先「仅预检」（纯只读）→ 确认无阻塞 → 「开始执行」

**清理**：完整预览 → 勾选确认 → 执行（可选「移入回收站」或「永久删除」）

---

## 安全模型

这是本项目的核心。所有设计围绕一个目标：**任何失败都不会破坏你的数据**。

### 执行顺序（不可调换）

```
预检 ──► 复制 ──► 校验 ──► 重命名 ──► 建链接 ──► 验证 ──► 删残留
 │        │        │         │          │         │        │
 不改任何  源不动   不一致就   毫秒级     失败可    读一个   失败也
 东西             不删源               秒回      文件     无所谓
```

- **复制阶段绝不碰源目录**。磁盘满、断电、进程被杀——源目录完好、程序照常运行，等于什么都没发生。
- **校验通过前绝不删源**。逐文件比对数量与字节数，差一个字节就停下。
- **用「重命名」代替「删除」做切换**。GB 级删除要几十秒，若先删源再建链接，中间会出现「源已消失、链接未建立」的窗口，程序打不开。改成重命名后这个窗口压缩到接近 0。
- **删残留前先 `rmdir` 摘掉重解析点**，绝不递归跟进链接目标。

### 三层回滚（自动选代价最低的）

| 方案 | 场景 | 实测耗时 | 数据移动 |
|---|---|---|---|
| **A 重命名回滚** | 原位置有 `.__migrating_*` 残留 | **6 ms** | **0 字节** |
| **B 补建链接** | 目标完整、原位置缺链接 | **25 ms** | **0 字节** |
| **C 完整搬回** | 链接已生效、用户就是要撤销 | 秒级 | 全部 |
| **D 清理孤儿** | 源完好、目标留有失败时的副本 | 秒级 | 0 字节（删副本） |

**核心原则：只要源目录没被真正删除，就永远不需要「搬回来」这种高成本回滚。**

### 13 项预检

`Junction 能力` `管理员身份` `源目录` `源类型` `黑名单` `卷` `目标占用`
`目标父目录` `可用空间` `内含链接` `运行中程序` `文件占用` `源可写` `目标可写`

其中 **11 项会导致预检失败**，3 项仅警告不阻断。任意一项 FAIL → **跳过该项，不做任何写操作**，且**不中断队列**。

### AI 只能降级，不能升级

用激进程度阶梯做**机械约束**，不靠提示词自觉：

```
keep(0) < review(1) < migrate(2) < delete(3)
```

- `BLOCK` / `ALREADY` 类**绝不发给 AI**
- 只有 `AI建议等级 < 规则判定等级` 时才生效（AI 行使否决，降级为 `REVIEW`）
- AI 更激进时**直接忽略**，仅作展示

### 清理功能的四层闸门

1. **只对 `DELETE` 生效** —— 可迁 / 待定 / 禁区不允许清理
2. **强制预览** —— 完整列出路径与体积，勾选确认后才可执行
3. **执行器独立再过滤** —— 不信任界面传来的内容
4. **硬禁区 + 链接安全** —— 盘符根 / Windows / Program Files / ProgramData / 用户主目录 / 回收站一律拒绝；遇 Junction 只删链接本身

---

## 命令接口

不想用界面的话，核心模块可直接调用：

```powershell
Import-Module .\MigrateCore.psm1

# 只计算不执行
Get-MigrationPlan -Source 'C:\Users\me\AppData\Local\某软件' -DestinationRoot 'D:\moved'

# 完整预检（只读）
$pre = Test-MigrationPrerequisite -Source 'C:\Users\me\AppData\Local\某软件' -DestinationRoot 'D:\moved'
$pre.Checks | Format-Table Name, Level, Message -AutoSize

# 执行迁移
$r = Start-DirectoryMigration -Source 'C:\Users\me\AppData\Local\某软件' -DestinationRoot 'D:\moved'

# 回滚
Undo-DirectoryMigration -ManifestPath $r.ManifestPath

# 迁移失败后在目标盘留下的孤儿副本，可一并清理
Undo-DirectoryMigration -ManifestPath $r.ManifestPath -CleanOrphanTarget
```

### 验收测试

```powershell
powershell -ExecutionPolicy Bypass -File .\Run-Acceptance.ps1
```

**15 条验收 / 58 项断言**，全部在一对临时目录上跑，覆盖：预检失败、
复制中断、校验不一致、`mklink` 失败、清理失败、中文与空格路径、
四种回滚方案、清理安全闸门、链接安全……**不碰任何真实数据**，结束后自动清理。

---

## 常见问题

<details>
<summary><b>需要管理员权限吗？</b></summary>

**不需要。** NTFS 上创建 Junction 只需对目标位置的写权限（只有符号链接 `/D` 才需要管理员或开发者模式）。
界面启动时会**实测**这个能力，而不是靠猜。
只有当源或目标位于受保护位置（如 `Program Files`）时才需要提权。
</details>

<details>
<summary><b>预检报「文件被占用」怎么办？</b></summary>

完全退出对应程序（**含系统托盘图标**），用任务管理器确认没有残留进程。

这是**保护机制**，不是 bug——数据库文件被占用时强行复制会损坏数据。
</details>

<details>
<summary><b>迁移后程序打不开怎么办？</b></summary>

运行「回滚上次执行」。它会自动选最低代价方案——如果只是链接丢了（方案 B），**25 毫秒**就能修好。
</details>

<details>
<summary><b>为什么「已迁」的目录显示 `—` 而不是体积？</b></summary>

因为那是链接，工具不跟进遍历（跟进会重复统计）。链接目标在说明栏显示，体积在目标盘，不重复计入。
</details>

<details>
<summary><b>能迁移 Program Files 里的程序吗？</b></summary>

默认不可以（软禁区，命令行需 `-Force -ForceReason "理由"`；**界面有意不提供这个入口**）。

原因：这类程序常依赖注册表绝对路径、Windows 服务、更新机制，迁移后可能损坏。
更稳的做法是用程序自己的设置改数据/缓存位置。
</details>

<details>
<summary><b>`Windows` / `ProgramData` 能迁吗？</b></summary>

不能。硬禁区，`-Force` 也解不开。
</details>

<details>
<summary><b>回收站为什么不能迁移也不能清理？</b></summary>

它是 Windows 管理的特殊目录，Junction 会被系统破坏。请用系统自带的「清空回收站」，
或通过「属性 → 自定义大小」限制它的容量，让它自动滚动清理。
</details>

更多问题见 [`docs/常见问题.md`](docs/常见问题.md)。

---

## 项目结构

```
Cpan_cleaner/
├── 启动-C盘迁移助手.cmd       双击启动器
├── MigrateGui.ps1             图形界面（四个标签页）
├── MigrateCore.psm1           迁移核心：预检 / 执行 / 回滚
├── Scan-CDrive.ps1            规则扫描与六级标注
├── Annotate-CDriveReport.ps1  AI 标注层（可选，不联网也能用）
├── Invoke-MigrationQueue.ps1  迁移队列执行器（界面以独立进程调用）
├── Clean-CDriveItems.ps1      清理执行器（带独立安全闸门）
├── Repair-Annotation-Encoding.ps1  标注结果编码乱码还原工具
├── Run-Acceptance.ps1         15 条验收测试
├── docs/
│   ├── 使用教程.md            图文详细教程
│   ├── 安全设计.md            完整安全模型说明
│   └── 常见问题.md            FAQ
├── CHANGELOG.md
└── LICENSE
```

运行后会自动生成 `report/` 目录，存放扫描报告、迁移 manifest 与清理日志。

> `report/migration/` 里的 `migrate-*.json` 是**回滚凭据**，请勿删除。

---

## 技术细节

<details>
<summary><b>为什么不用 robocopy 的 /MOVE？</b></summary>

跨卷 `/MOVE` 会边复制边删源，中途失败会留下「源删了一半、目标不完整」的状态。
本项目改为**先完整复制 → 校验 → 再原子切换**，把风险窗口压缩到最小。
</details>

<details>
<summary><b>robocopy 退出码为什么要特殊处理？</b></summary>

robocopy 的退出码是**位标志**：`0–7` 全部表示成功（1 = 成功复制了文件），
`>= 8` 才是失败。直接写 `if ($LASTEXITCODE -ne 0) { 失败 }` 会 100% 误报。

本项目还额外处理了「进程被强杀返回负值」的情况。
</details>

<details>
<summary><b>PowerShell 5.1 的 UTF-8 坑</b></summary>

`Invoke-RestMethod` 在服务端 `Content-Type` 不带 `charset=utf-8` 时，会按 **ISO-8859-1** 解码响应体，
中文全变成 `åæ¶ç«` 这种 mojibake。本项目改为自行取原始字节按 UTF-8 解码，
并提供 `Repair-Annotation-Encoding.ps1` 用于还原已经被写坏的标注结果。

另外所有 `.ps1`/`.psm1` 均以 **UTF-8 with BOM** 保存——否则 PowerShell 5.1 会按 ANSI 读取，中文直接语法报错。
</details>

<details>
<summary><b>Junction 只删链接，不删目标</b></summary>

删除 Junction 时必须用 `rmdir`（不带 `/S`）。
用 `rd /s` 或 `Remove-Item -Recurse` 会**顺着链接把目标盘的真实数据一起删掉**。
本项目所有删除路径都做了这个区分。
</details>

---

## 贡献

欢迎提 Issue 和 PR。改动前建议先跑一遍 `Run-Acceptance.ps1` 确认没有回归。

新增功能请**同时补验收断言**——本项目所有安全相关行为都有对应的测试覆盖。

---

## 许可证

[MIT License](LICENSE) © 2026 wang1413520
