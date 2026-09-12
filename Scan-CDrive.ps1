#Requires -Version 5.1
<#
.SYNOPSIS
    C 盘扫描与迁移分级工具（阶段 1：纯规则引擎，不联网）

.DESCRIPTION
    扫描指定盘的候选目录，基于确定性规则输出六类判定：

      DELETE   可删   —— 缓存/临时/日志/安装包残留，直接清理，无需迁移
      MIGRATE  可迁   —— 应用数据目录，适合用 Junction 迁移到其他盘
      REDIRECT 重定向 —— 用户 Shell 文件夹，应改用系统「位置」功能，不是 Junction
      REVIEW   待定   —— 规则无法定性，需人工确认（阶段 2 交由 AI 标注）
      ALREADY  已迁   —— 已经是链接，无需处理
      BLOCK    禁区   —— 绝对不可迁移

    输出：控制台报告 + JSON + CSV + 纯路径清单（均为目录级绝对路径）

.PARAMETER Root
    要扫描的盘符，默认系统盘

.PARAMETER MinSizeMB
    只列出大于此体积的目录，默认 50 MB

.PARAMETER OutDir
    报告输出目录，默认当前目录

.EXAMPLE
    .\Scan-CDrive.ps1
    .\Scan-CDrive.ps1 -MinSizeMB 200 -OutDir D:\report
#>
[CmdletBinding()]
param(
    [string]$Root = "$env:SystemDrive\",
    [int]$MinSizeMB = 50,
    [string]$OutDir = (Get-Location).Path
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
$script:MinBytes = [int64]$MinSizeMB * 1MB
$SD = $env:SystemDrive

# ============================================================
#  规则表（调整判定策略只需改这里）
# ============================================================

# 【A】整棵子树禁止迁移
$script:BlockSubtree = @(
    "$SD\Windows"
    "$SD\`$Recycle.Bin"
    "$SD\System Volume Information"
    "$SD\Recovery"
    "$SD\PerfLogs"
    "$SD\Boot"
    "$SD\inetpub"
    "$SD\Documents and Settings"
    "$SD\MSOCache"
    "$SD\Config.Msi"
)

# 【B】仅目录本身禁止迁移（子目录单独评估）
$script:BlockExactOnly = @(
    "$SD"
    "$SD\Users"
    "$SD\Program Files"
    "$SD\Program Files (x86)"
    "$SD\ProgramData"
    "$SD\Users\*\AppData"
    "$SD\Users\*\AppData\Local\Microsoft"
)

# 【C】路径包含这些片段 -> 禁止迁移
$script:BlockContains = @(
    '\AppData\Local\Packages'
    '\WindowsApps'
    'Application Data\'
    'Local Settings\'
    '\AppData\Local\Microsoft\Windows\'
    '\AppData\Roaming\Microsoft'
    '\Program Files\Common Files'
    '\Program Files (x86)\Common Files'
    '\Program Files\Windows '
    '\Program Files\Internet Explorer'
    '\Program Files\Uninstall Information'
    '\Program Files\dotnet'
    '\Program Files\NVIDIA'
    '\Program Files\Microsoft'
    '\Program Files\ModifiableWindowsApps'
    '\Program Files\Reference Assemblies'
    '\Program Files\MSBuild'
    '\Program Files\IIS'
    '\Program Files\Lenovo'
    '\Program Files\AntiCheatExpert'
    '\Program Files (x86)\Microsoft'
    '\Program Files (x86)\Windows Kits'
    '\Program Files (x86)\Reference Assemblies'
    '\Program Files (x86)\MSBuild'
    '\Program Files (x86)\Windows '
    '\Program Files (x86)\Internet Explorer'
    '\Program Files (x86)\Microsoft.NET'
    '\Program Files (x86)\Microsoft XNA'
    '\Program Files (x86)\Lenovo'
    '\ProgramData\Microsoft'
    '\ProgramData\Lenovo'
    '\Users\Public'
)

# 【D】可删白名单（最高优先级，可穿透 A/B/C）
$script:DeleteWhitelist = @(
    '\ProgramData\Package Cache'
    '\ProgramData\NVIDIA Corporation\NV_Cache'
    "$SD\`$Recycle.Bin"
)

# 【E】可删：路径包含这些片段
$script:DeleteContains = @(
    '\AppData\Local\Temp'
    '\AppData\Local\CrashDumps'
    '\AppData\Local\pip'
    '\AppData\Local\npm-cache'
    '\AppData\Local\Yarn\Cache'
    '\AppData\Local\NuGet\v3-cache'
    '\AppData\Local\Microsoft\Edge\User Data\Default\Cache'
    '\AppData\Local\Microsoft\Edge\User Data\Default\Code Cache'
    '\AppData\Local\Google\Chrome\User Data\Default\Cache'
    '\AppData\Local\Google\Chrome\User Data\Default\Code Cache'
    '\AppData\Local\Google\Chrome\User Data\OptGuideOnDeviceModel'
    '\AppData\Local\D3DSCache'
    '\AppData\Local\JetBrains\Daemon'
)

# 【F】用户 Shell 文件夹 -> 用系统「位置」重定向
$script:ShellFolders = @(
    'Desktop','Documents','Downloads','Pictures','Music','Videos',
    'Favorites','Links','Saved Games','Contacts','Searches','3D Objects'
)

# 【G】云同步目录 -> 用同步客户端自身的设置改位置
$script:CloudSyncNames = @(
    'OneDrive','OneDrive - *','WPS Cloud Files','iCloudDrive','iCloud Drive',
    'Dropbox','Google Drive','Nutstore','Nutstore Files','BaiduNetdiskDownload',
    'Bluecloud','CloudDrive','坚果云'
)

# 【H】可删：目录名通配
$script:DeleteNamePatterns = @(
    'Temp','tmp','Cache','*Cache','*Cache*','CacheStorage','Code Cache',
    'GPUCache','ShaderCache','CrashDumps','Crashpad','Installation*','tmp_*','*-updater'
)

# 【I】构建缓存：删了要重建 -> 保守 REVIEW
$script:BuildCacheNames = @('__pycache__','.pytest_cache','.mypy_cache','.ruff_cache','node_modules','target','build','dist','out')

# 【J】工具链目录：可能被环境变量/IDE 记录绝对路径 -> 保守 REVIEW
$script:ToolchainNames = @(
    '.jdks','.m2','.gradle','.conda','.anaconda','.nuget','.cargo','.rustup',
    'mingw64','MinGW','msys64','STM32Cube','.stm32cubemx','.stmcufinder',
    '.android','Android','.dotnet','anaconda3','Anaconda3','Python','Scripts',
    'nodejs','Nodejs','Programs','Roaming'
)

$script:InstallerExts = @('.zip','.7z','.rar','.exe','.msi','.iso','.tar','.gz','.xz','.whl','.vsix','.cab','.dmg','.pkg')

# ============================================================
#  工具函数
# ============================================================

function Get-DirectoryFacts {
    param([Parameter(Mandatory)][string]$Path)

    $zero = [pscustomobject]@{
        Bytes = [int64]0; Files = 0; ExtBytes = @{}; ChildNames = @()
        ReparsePoints = @(); HasWal = $false; HasShm = $false; LockedFiles = 0
        IsReparseRoot = $false
    }

    # 根路径本身是重解析点：不要跟进遍历（否则会重复统计目标目录）
    $root = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($root -and ($root.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        $zero.IsReparseRoot = $true
        return $zero
    }

    $bytes = [int64]0; $files = 0
    $extBytes = @{}
    $reparse = New-Object System.Collections.ArrayList
    $hasWal = $false; $hasShm = $false; $locked = 0
    $childNames = @()

    try {
        $childNames = @(Get-ChildItem -LiteralPath $Path -Force -Directory -EA SilentlyContinue |
            Select-Object -ExpandProperty Name)
    } catch {}

    $stack = New-Object System.Collections.Stack
    $stack.Push($Path)

    while ($stack.Count -gt 0) {
        $cur = $stack.Pop()
        $di = $null
        try { $di = New-Object System.IO.DirectoryInfo $cur } catch { continue }

        try {
            foreach ($f in $di.EnumerateFiles()) {
                try {
                    $len = $f.Length
                    $bytes += $len; $files++
                    $ext = $f.Extension.ToLower()
                    if ([string]::IsNullOrEmpty($ext)) { $ext = '(noext)' }
                    if ($extBytes.ContainsKey($ext)) { $extBytes[$ext] += $len } else { $extBytes[$ext] = $len }
                    if ($ext -eq '.sqlite-wal') { $hasWal = $true }
                    if ($ext -eq '.sqlite-shm') { $hasShm = $true }
                    if ($locked -lt 30 -and $len -gt 2MB) {
                        $fs = $null
                        try { $fs = [System.IO.File]::Open($f.FullName, 'Open', 'Read', 'None') }
                        catch { $locked++ }
                        finally { if ($fs) { $fs.Dispose() } }
                    }
                } catch {}
            }
        } catch {}

        try {
            foreach ($sub in $di.EnumerateDirectories()) {
                try {
                    if ($sub.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                        [void]$reparse.Add($sub.FullName); continue
                    }
                    $stack.Push($sub.FullName)
                } catch {}
            }
        } catch {}
    }

    [pscustomobject]@{
        Bytes = $bytes; Files = $files; ExtBytes = $extBytes; ChildNames = $childNames
        ReparsePoints = $reparse; HasWal = $hasWal; HasShm = $hasShm; LockedFiles = $locked
        IsReparseRoot = $false
    }
}

function Get-TopExtensions {
    param($ExtBytes, [int]$Top = 4)
    if (-not $ExtBytes -or $ExtBytes.Count -eq 0) { return '' }
    $total = ($ExtBytes.Values | Measure-Object -Sum).Sum
    if ($total -le 0) { return '' }
    ($ExtBytes.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First $Top |
        ForEach-Object { "{0} {1:N0}%" -f $_.Key, (100 * $_.Value / $total) }) -join ', '
}

function Test-Prefix {
    param([string]$Path, [string[]]$Prefixes)
    foreach ($p in $Prefixes) {
        if ($Path -ieq $p) { return $true }
        if ($Path.StartsWith($p + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Test-Contains {
    param([string]$Path, [string[]]$Fragments)
    foreach ($f in $Fragments) {
        if ($Path.IndexOf($f, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
    }
    return $false
}

function Get-LinkTarget {
    <#
    .SYNOPSIS
        读取链接/联接的目标路径。
        PS 5.1 的 .Target 读不到旧式兼容链接（如 C:\Users\All Users），
        此函数回退用 `dir /AL` 解析，并按父目录缓存结果。
    #>
    param([string]$Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    $t = ''
    if ($item) { $t = ($item.Target -join ',') }
    if ($t) { return $t }

    $parent = Split-Path $Path -Parent
    $name   = Split-Path $Path -Leaf
    if (-not $parent) { return '' }

    if (-not $script:LinkTargetCache) { $script:LinkTargetCache = @{} }
    if (-not $script:LinkTargetCache.ContainsKey($parent)) {
        $map = @{}
        try {
            $lines = cmd.exe /c "dir /AL `"$parent`"" 2>$null
            foreach ($ln in @($lines)) {
                $m = [regex]::Match([string]$ln, '^\s*\S+\s+\S+\s+<(\w+)>\s+(.+?)\s+\[(.+)\]\s*$')
                if ($m.Success) { $map[$m.Groups[2].Value.Trim()] = $m.Groups[3].Value.Trim() }
            }
        } catch {}
        $script:LinkTargetCache[$parent] = $map
    }
    if ($script:LinkTargetCache.ContainsKey($parent) -and $script:LinkTargetCache[$parent].ContainsKey($name)) {
        return $script:LinkTargetCache[$parent][$name]
    }
    # 找不到目标 = 是重解析点但不是链接（如 OneDrive 云占位），返回空串由调用方区分
    return ''
}

function New-Verdict {
    param([string]$V, [string]$R, [string]$C = 'high')
    [pscustomobject]@{ Verdict = $V; Reason = $R; Confidence = $C }
}

# ============================================================
#  规则引擎：唯一的决策来源
# ============================================================

function Get-Verdict {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Facts
    )

    $gb = $Facts.Bytes / 1GB

    # ---------- 1. 已是链接 ----------
    if ($Facts.IsReparseRoot) {
        $tgt = Get-LinkTarget -Path $Path
        if ($tgt) { return New-Verdict 'ALREADY' "已经是链接，无需处理  ->  $tgt" }
        # 是重解析点但不是链接：云同步占位（OneDrive 等）、去重占位等，一律不可迁移
        return New-Verdict 'BLOCK' '重解析点但非链接（云同步/去重占位目录），不可迁移'
    }

    # ---------- 2. 驱动器根 ----------
    if ($Path.TrimEnd('\') -match '^[A-Za-z]:$') {
        return New-Verdict 'BLOCK' '驱动器根目录'
    }

    # ---------- 3. 可删白名单（穿透禁区） ----------
    if (Test-Contains -Path $Path -Fragments $script:DeleteWhitelist) {
        if ($Path -like '*`$Recycle.Bin*') {
            return New-Verdict 'DELETE' '回收站内容，清空即可（不要迁移）'
        }
        return New-Verdict 'DELETE' '安装器/驱动缓存，可直接清理'
    }

    # ---------- 4. 整棵子树禁区 ----------
    if (Test-Prefix -Path $Path -Prefixes $script:BlockSubtree) {
        return New-Verdict 'BLOCK' '系统目录，绝对不可迁移'
    }

    # ---------- 5. 仅本目录禁区 ----------
    foreach ($pat in $script:BlockExactOnly) {
        if ($Path -like $pat) {
            return New-Verdict 'BLOCK' '容器目录（含系统子目录），不可整体迁移；只能迁其子目录'
        }
    }
    if ($Path -match '^[A-Za-z]:\\Users\\[^\\]+$') {
        return New-Verdict 'BLOCK' '用户主目录本身，不可迁移（其子目录单独评估）'
    }

    # ---------- 6. 路径片段禁区 ----------
    if (Test-Contains -Path $Path -Fragments $script:BlockContains) {
        return New-Verdict 'BLOCK' '系统/受保护组件目录'
    }

    # ---------- 7. 程序安装目录根 ----------
    foreach ($pfr in @("$SD\Program Files", "$SD\Program Files (x86)")) {
        if ($Path -ieq $pfr) { return New-Verdict 'BLOCK' '程序安装目录根，不可整体迁移' }
    }

    # ---------- 8. 用户 Shell 文件夹 -> 官方重定向 ----------
    $parentIsUserHome = (Split-Path $Path -Parent) -match '^[A-Za-z]:\\Users\\[^\\]+$'
    if ($parentIsUserHome -and ($script:ShellFolders -contains $Name)) {
        return New-Verdict 'REDIRECT' '用户文件夹：用「属性 -> 位置 -> 移动」重定向，不要用 Junction'
    }

    # ---------- 9. 云同步目录 ----------
    foreach ($c in $script:CloudSyncNames) {
        if ($Name -like $c) {
            return New-Verdict 'REVIEW' '云同步目录：用同步客户端自身的设置改位置，Junction 可能导致同步异常' 'medium'
        }
    }

    # ---------- 10. 可删（路径片段） ----------
    if (Test-Contains -Path $Path -Fragments $script:DeleteContains) {
        return New-Verdict 'DELETE' '缓存/临时目录，可安全清理'
    }

    # ---------- 11. 可删（目录名通配） ----------
    foreach ($pat in $script:DeleteNamePatterns) {
        if ($Name -like $pat) {
            return New-Verdict 'DELETE' "缓存/日志/临时目录（匹配 $pat）"
        }
    }

    # ---------- 12. 纯缓存容器：所有直接子目录都是缓存 -> 整体可删 ----------
    if ($Facts.ChildNames.Count -gt 0) {
        $allCache = $true
        foreach ($cn in $Facts.ChildNames) {
            $hit = $false
            foreach ($pat in $script:DeleteNamePatterns) { if ($cn -like $pat) { $hit = $true; break } }
            if (-not $hit) { $allCache = $false; break }
        }
        if ($allCache) {
            return New-Verdict 'DELETE' ("仅含缓存子目录（{0}），可整体清理" -f ($Facts.ChildNames -join ', '))
        }
    }

    # ---------- 13. 构建缓存 -> 保守 REVIEW ----------
    if ($script:BuildCacheNames -contains $Name) {
        return New-Verdict 'REVIEW' "构建缓存（$Name），删除后需重新安装/构建" 'medium'
    }

    # ---------- 14. 工具链目录 -> 保守 REVIEW ----------
    if ($script:ToolchainNames -contains $Name) {
        return New-Verdict 'REVIEW' '工具链/容器目录：可能被环境变量或 IDE 记录绝对路径，迁移前需确认' 'medium'
    }

    # ---------- 15. 安装包残留启发式 ----------
    if ($Facts.Files -gt 0 -and $Facts.Files -le 80 -and $gb -ge 0.3 -and $Facts.ExtBytes.Count -gt 0) {
        $totalB = ($Facts.ExtBytes.Values | Measure-Object -Sum).Sum
        $instB = 0
        foreach ($k in $Facts.ExtBytes.Keys) {
            if ($script:InstallerExts -contains $k) { $instB += $Facts.ExtBytes[$k] }
        }
        if ($totalB -gt 0 -and ($instB / $totalB) -ge 0.8) {
            return New-Verdict 'DELETE' '疑似安装包残留（80%+ 为压缩包/安装程序），装完即无用' 'medium'
        }
    }

    # ---------- 16. 程序安装目录子项 -> REVIEW ----------
    if (Test-Prefix -Path $Path -Prefixes @("$SD\Program Files", "$SD\Program Files (x86)")) {
        return New-Verdict 'REVIEW' '程序安装目录子项：迁移可能破坏注册表/服务/更新机制，需逐个评估' 'medium'
    }

    # ---------- 17. AppData 子项 -> 可迁 ----------
    if ($Path -match '\\AppData\\(Local|Roaming|LocalLow)\\[^\\]+$') {
        $warn = ''
        if ($Facts.HasWal -or $Facts.HasShm) { $warn += '；检测到 SQLite WAL，迁移前必须完全退出对应程序' }
        if ($Facts.LockedFiles -gt 0) { $warn += "；$($Facts.LockedFiles) 个大文件正被占用" }
        $conf = if ($warn) { 'medium' } else { 'high' }
        return New-Verdict 'MIGRATE' "应用数据目录，适合 Junction 迁移$warn" $conf
    }

    # ---------- 18. 用户主目录子项 -> 可迁 ----------
    if ($parentIsUserHome) {
        $warn = ''
        if ($Facts.HasWal -or $Facts.HasShm) { $warn += '；检测到 SQLite WAL，迁移前必须完全退出对应程序' }
        if ($Facts.LockedFiles -gt 0) { $warn += "；$($Facts.LockedFiles) 个大文件正被占用" }
        $conf = if ($warn) { 'medium' } else { 'high' }
        return New-Verdict 'MIGRATE' "用户级应用数据目录，适合 Junction 迁移$warn" $conf
    }

    # ---------- 兜底 ----------
    return New-Verdict 'REVIEW' '规则无法定性，需人工确认' 'low'
}

# ============================================================
#  扫描主流程
# ============================================================

$startTime = Get-Date

$scanRoots = New-Object System.Collections.ArrayList
[void]$scanRoots.Add($Root)
[void]$scanRoots.Add("$Root`Users")

Get-ChildItem -LiteralPath "$Root`Users" -Force -Directory -EA SilentlyContinue |
    Where-Object { $_.Name -notin @('Public','Default','Default User','All Users') } |
    ForEach-Object {
        [void]$scanRoots.Add($_.FullName)
        [void]$scanRoots.Add((Join-Path $_.FullName 'AppData\Local'))
        [void]$scanRoots.Add((Join-Path $_.FullName 'AppData\Roaming'))
        [void]$scanRoots.Add((Join-Path $_.FullName 'AppData\LocalLow'))
    }
foreach ($d in @('Program Files','Program Files (x86)','ProgramData')) {
    [void]$scanRoots.Add("$Root$d")
}
$scanRoots = @($scanRoots | Where-Object { $_ -and (Test-Path -LiteralPath $_) })

# 容器集合 = 扫描根自身 + 所有祖先（容器不计为候选，避免重复遍历与噪音）
$containerSet = @{}
foreach ($r in $scanRoots) {
    $full = $r.TrimEnd('\')
    $containerSet[$full.ToLower()] = $true
    $cur = $full
    while ($cur -match '\\') {
        $cur = Split-Path $cur -Parent
        if (-not $cur) { break }
        $containerSet[$cur.ToLower()] = $true
    }
}

Write-Host ""
Write-Host ("=" * 78)
Write-Host (" C 盘迁移扫描  --  {0}" -f $startTime.ToString('yyyy-MM-dd HH:mm:ss'))
Write-Host (" 规则: 纯本地确定性规则，不联网、不调用任何 API")
Write-Host (" 阈值: 仅列出 > {0} MB 的目录" -f $MinSizeMB)
Write-Host ("=" * 78)

$results = New-Object System.Collections.ArrayList

foreach ($scanRoot in $scanRoots) {
    Write-Host ("`n[扫描] {0}" -f $scanRoot) -NoNewline
    $dirs = @(Get-ChildItem -LiteralPath $scanRoot -Force -Directory -EA SilentlyContinue)
    $hits = 0

    foreach ($d in $dirs) {
        $key = $d.FullName.TrimEnd('\').ToLower()
        if ($containerSet.ContainsKey($key)) { continue }

        $facts = Get-DirectoryFacts -Path $d.FullName
        $v = Get-Verdict -Path $d.FullName -Name $d.Name -Facts $facts

        # 重解析点的体积记为 0（不跟进遍历），必须以「是否重解析点」豁免体积门槛，
        # 否则它们无论判成 ALREADY 还是 BLOCK 都会被 MinSizeMB 误滤掉
        if (-not $facts.IsReparseRoot -and $facts.Bytes -lt $script:MinBytes) { continue }

        [void]$results.Add([pscustomobject]@{
            Verdict       = $v.Verdict
            Path          = $d.FullName
            Name          = $d.Name
            SizeGB        = [math]::Round($facts.Bytes / 1GB, 3)
            SizeBytes     = $facts.Bytes
            Files         = $facts.Files
            Reason        = $v.Reason
            Confidence    = $v.Confidence
            TopExtensions = (Get-TopExtensions -ExtBytes $facts.ExtBytes)
            ReparseCount  = $facts.ReparsePoints.Count
            HasWal        = $facts.HasWal
            LockedFiles   = $facts.LockedFiles
        })
        $hits++
    }
    Write-Host ("   -> {0} 项" -f $hits)
}

$elapsed = ((Get-Date) - $startTime).TotalSeconds

# ============================================================
#  报告
# ============================================================

$order = @('DELETE','MIGRATE','REDIRECT','REVIEW','ALREADY','BLOCK')
$labels = @{
    DELETE   = '可删   DELETE   —— 直接清理，无需迁移'
    MIGRATE  = '可迁   MIGRATE  —— 适合 Junction 迁移'
    REDIRECT = '重定向 REDIRECT —— 用系统「位置」功能，不是 Junction'
    REVIEW   = '待定   REVIEW   —— 需人工确认'
    ALREADY  = '已迁   ALREADY  —— 已经是链接，无需处理'
    BLOCK    = '禁区   BLOCK    —— 绝对不可迁移'
}

Write-Host ""
Write-Host ("=" * 78)
Write-Host " 汇总"
Write-Host ("=" * 78)
Write-Host ("扫描根 {0} 个 | 候选目录 {1} 个 | 耗时 {2:N0} 秒" -f $scanRoots.Count, $results.Count, $elapsed)

$grandTotal = [int64]0
foreach ($v in $order) {
    $set = @($results | Where-Object { $_.Verdict -eq $v } | Sort-Object SizeBytes -Descending)
    $sum = [int64](($set | Measure-Object SizeBytes -Sum).Sum)
    if (-not $sum) { $sum = 0 }
    if ($v -in @('DELETE','MIGRATE','REDIRECT')) { $grandTotal += $sum }

    Write-Host ""
    Write-Host ("-" * 78)
    if ($v -eq 'ALREADY') {
        Write-Host ("[{0}]  {1} 项（均为链接，体积不计入统计）" -f $labels[$v], $set.Count)
    } else {
        Write-Host ("[{0}]  {1} 项 / {2:N2} GB" -f $labels[$v], $set.Count, ($sum/1GB))
    }
    Write-Host ("-" * 78)
    if ($set.Count -eq 0) { Write-Host "  (无)"; continue }
    foreach ($r in $set) {
        if ($r.Verdict -eq 'ALREADY') {
            Write-Host ("  {0,12}  {1}" -f '—', $r.Path)
        } else {
            Write-Host ("  {0,9:N2} GB  {1}" -f $r.SizeGB, $r.Path)
        }
        Write-Host ("  {0}{1}" -f (' ' * 12), $r.Reason)
    }
}

Write-Host ""
Write-Host ("=" * 78)
Write-Host (" 可操作空间合计（可删 + 可迁 + 可重定向）: {0:N2} GB" -f ($grandTotal/1GB))
Write-Host (" 注: 统计已排除重解析点，故体积可能小于资源管理器显示值")
Write-Host ("     已迁(ALREADY)项为链接，其体积在链接目标所在盘，不重复计入本表")
Write-Host ("=" * 78)

# ---- 导出 ----
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$stamp    = $startTime.ToString('yyyyMMdd-HHmmss')
$jsonPath = Join-Path $OutDir "cdrive-scan-$stamp.json"
$csvPath  = Join-Path $OutDir "cdrive-scan-$stamp.csv"

$results | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
$results | Select-Object Verdict, SizeGB, Files, Path, Confidence, Reason, TopExtensions |
    Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8

foreach ($v in $order) {
    $set = @($results | Where-Object { $_.Verdict -eq $v } | Sort-Object SizeBytes -Descending)
    if ($set.Count -eq 0) { continue }
    $lp = Join-Path $OutDir ("list-{0}.txt" -f $v.ToLower())
    $lines = foreach ($r in $set) {
        if ($r.Verdict -eq 'ALREADY') { "# {0,12}  {1}" -f '—', $r.Reason }
        else { "# {0,8:N2} GB  {1}" -f $r.SizeGB, $r.Reason }
        $r.Path
    }
    Set-Content -LiteralPath $lp -Value $lines -Encoding UTF8
}

Write-Host ""
Write-Host " 已导出："
Write-Host ("   JSON : {0}" -f $jsonPath)
Write-Host ("   CSV  : {0}" -f $csvPath)
Write-Host ("   清单 : {0}\list-*.txt" -f (Resolve-Path $OutDir).Path)
Write-Host ""
Write-Host " 本工具只做扫描和分级，不执行任何删除或迁移操作。"
Write-Host ""
