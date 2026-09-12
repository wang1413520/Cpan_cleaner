#Requires -Version 5.1
<#
.SYNOPSIS
    C 盘目录迁移核心模块 —— 复制校验 + 原子切换 + 可回滚

.DESCRIPTION
    把某个目录物理迁移到另一个卷，并在原位置建立目录联接（Junction），
    使原程序路径不变、照常启动。

    安全设计（每一条都是踩过的坑）：
      · 复制阶段绝不碰源目录 —— 此阶段任何失败，源完好、程序照常运行
      · 校验通过前绝不删源
      · 用「重命名」而非「删除」做切换，把「源消失但链接未建」的窗口压到毫秒级
      · 回滚优先用零数据移动的方案（重命名 / 补链接），最后才搬回来
      · robocopy 退出码 0-7 全部算成功，>=8 才算失败

    公开函数：
      Get-MigrationPlan              只计算不执行
      Test-MigrationPrerequisite     完整预检
      Start-DirectoryMigration       执行迁移
      Undo-DirectoryMigration        回滚（自动选择代价最低的方案）

.NOTES
    需要管理员权限。所有操作使用 -LiteralPath，不跟随源目录内的重解析点。
#>

$ErrorActionPreference = 'Stop'

$script:SD = $env:SystemDrive
$script:ManifestVersion = 1

# ============================================================
#  黑名单
# ============================================================

# 硬拒绝：任何情况都不允许（-Force 也解不开）
$script:HardBlockExact = @(
    "$script:SD"
    "$script:SD\Users"
    "$script:SD\Program Files"
    "$script:SD\Program Files (x86)"
    "$script:SD\ProgramData"
    "$script:SD\Windows"
    "$script:SD\`$Recycle.Bin"
    "$script:SD\System Volume Information"
    "$script:SD\Recovery"
    "$script:SD\PerfLogs"
    "$script:SD\Boot"
    "$script:SD\inetpub"
    "$script:SD\Documents and Settings"
    "$script:SD\MSOCache"
    "$script:SD\Config.Msi"
)

$script:HardBlockSubtree = @(
    "$script:SD\Windows"
    "$script:SD\ProgramData"
    "$script:SD\`$Recycle.Bin"
    "$script:SD\System Volume Information"
    "$script:SD\Recovery"
    "$script:SD\PerfLogs"
    "$script:SD\Documents and Settings"
)

$script:HardBlockContains = @(
    '\WindowsApps'
    '\AppData\Local\Packages'
    '\AppData\Local\Microsoft\Windows'
    'Application Data\'
    'Local Settings\'
)

# 软拒绝：需 -Force 且必须给出 -ForceReason 才放行
$script:SoftBlockPrefixes = @(
    "$script:SD\Program Files"
    "$script:SD\Program Files (x86)"
)

# ============================================================
#  内部工具函数
# ============================================================

function Test-IsAdmin {
    try {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = New-Object System.Security.Principal.WindowsPrincipal($id)
        return $pr.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Get-PathRootSafe {
    param([string]$Path)
    try {
        $full = [System.IO.Path]::GetFullPath($Path)
        return [System.IO.Path]::GetPathRoot($full)
    } catch { return $null }
}

function Get-DirStat {
    <#
    .SYNOPSIS
        统计目录的文件数/字节数，默认跳过重解析点（不跟进，也不计入）
    #>
    param([Parameter(Mandatory)][string]$Path, [switch]$IncludeReparse)

    $bytes = [int64]0; $files = 0
    $reparse = New-Object System.Collections.ArrayList
    $stack = New-Object System.Collections.Stack
    $stack.Push($Path)

    while ($stack.Count -gt 0) {
        $cur = $stack.Pop()
        $di = $null
        try { $di = New-Object System.IO.DirectoryInfo $cur } catch { continue }
        try {
            foreach ($f in $di.EnumerateFiles()) {
                try { $bytes += $f.Length; $files++ } catch {}
            }
        } catch {}
        try {
            foreach ($sub in $di.EnumerateDirectories()) {
                try {
                    if ($sub.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                        [void]$reparse.Add($sub.FullName)
                        if ($IncludeReparse) { $stack.Push($sub.FullName) }
                        continue
                    }
                    $stack.Push($sub.FullName)
                } catch {}
            }
        } catch {}
    }
    [pscustomobject]@{ Files = $files; Bytes = $bytes; ReparsePoints = $reparse }
}

function Get-LinkTargetPath {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return '' }
    if (-not ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { return '' }
    $t = ($item.Target -join ',')
    if ($t) { return $t }
    $parent = Split-Path $Path -Parent
    $name = Split-Path $Path -Leaf
    if (-not $parent) { return '' }
    try {
        $lines = cmd.exe /c "dir /AL `"$parent`"" 2>$null
        foreach ($ln in @($lines)) {
            $m = [regex]::Match([string]$ln, '^\s*\S+\s+\S+\s+<(\w+)>\s+(.+?)\s+\[(.+)\]\s*$')
            if ($m.Success -and $m.Groups[2].Value.Trim() -eq $name) { return $m.Groups[3].Value.Trim() }
        }
    } catch {}
    return ''
}

function Get-FreeSpaceBytes {
    param([string]$Path)
    $root = Get-PathRootSafe $Path
    if (-not $root) { return -1 }
    try {
        $d = New-Object System.IO.DriveInfo $root
        return [int64]$d.AvailableFreeSpace
    } catch { return -1 }
}

function New-Check {
    param([string]$Name, [string]$Level, [string]$Message)
    [pscustomobject]@{ Name = $Name; Level = $Level; Message = $Message }
}

function Get-RobocopyPath {
    $c = Join-Path $env:SystemRoot 'System32\robocopy.exe'
    if (Test-Path -LiteralPath $c) { return $c }
    return 'robocopy.exe'
}

function Invoke-RobocopyExe {
    <#
    .SYNOPSIS
        运行 robocopy 并返回退出码，同时支持进度回调。

    .DESCRIPTION
        必须用 ProcessStartInfo + Process.Start，不能用 Start-Process -PassThru：
        后者在不加 -Wait 时进程句柄已被释放，读取 ExitCode 会抛
        "You cannot call a method on a null-valued expression"。
        而我们需要边复制边报进度，不能加 -Wait。

        返回值为 int；若无法读取则返回 $null（调用方必须按「失败」处理）。
    #>
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$ProgressLog,
        [int]$TotalFiles = 0,
        [scriptblock]$OnTick
    )

    $exe = Get-RobocopyPath
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = ($Arguments -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    while (-not $proc.HasExited) {
        Start-Sleep -Milliseconds 400
        if ($OnTick) {
            $done = 0
            try {
                if ($ProgressLog -and (Test-Path -LiteralPath $ProgressLog)) {
                    $done = @(Get-Content -LiteralPath $ProgressLog -ErrorAction SilentlyContinue).Count
                }
            } catch {}
            try { & $OnTick ([int]$done) ([int]$TotalFiles) } catch {}
        }
    }

    $code = $null
    try { $code = [int]$proc.ExitCode } catch {}
    if ($null -eq $code) {
        try { $proc.WaitForExit(); $code = [int]$proc.ExitCode } catch {}
    }
    return $code
}

function Write-Manifest {
    param([Parameter(Mandatory)]$Manifest, [Parameter(Mandatory)][string]$Path)
    $Manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
}
function Read-Manifest {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "manifest 不存在：$Path" }
    $m = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    return $m
}
function Add-Step {
    param($Manifest, [string]$Step, [bool]$Ok, [string]$Note = '')
    $entry = [pscustomobject]@{
        Step = $Step
        At   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Ok   = $Ok
        Note = $Note
    }
    $Manifest.Steps = @($Manifest.Steps) + $entry
}

function Invoke-Progress {
    param($Callback, [string]$Step, [int]$Current, [int]$Total, [string]$Message = '')
    if (-not $Callback) { return }
    try {
        & $Callback ([pscustomobject]@{
            Step = $Step; Current = $Current; Total = $Total; Message = $Message
        })
    } catch {}
}

# ============================================================
#  公开函数 1：Get-MigrationPlan
# ============================================================

function Get-MigrationPlan {
    <#
    .SYNOPSIS
        只计算不执行：算出最终目标路径、体积、所需空间、内含重解析点。

    .PARAMETER Source
        要迁移的目录绝对路径

    .PARAMETER DestinationRoot
        目标盘的父目录（最终路径 = DestinationRoot\源文件夹名）

    .EXAMPLE
        Get-MigrationPlan -Source 'C:\Users\me\AppData\Local\JetBrains' -DestinationRoot 'D:\moved'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$DestinationRoot
    )

    $src = $Source.TrimEnd('\')
    $srcName = Split-Path $src -Leaf
    $target = Join-Path $DestinationRoot.TrimEnd('\') $srcName

    $srcRoot = Get-PathRootSafe $src
    $dstRoot = Get-PathRootSafe $DestinationRoot

    $stat = [pscustomobject]@{ Files = 0; Bytes = [int64]0; ReparsePoints = @() }
    $exists = Test-Path -LiteralPath $src
    if ($exists) { $stat = Get-DirStat -Path $src }

    $free = if ($dstRoot) { Get-FreeSpaceBytes $DestinationRoot } else { -1 }
    $need = [int64][math]::Ceiling($stat.Bytes * 1.15)

    # 内含重解析点的详情
    $rpDetail = @()
    foreach ($rp in @($stat.ReparsePoints)) {
        $rpDetail += [pscustomobject]@{ Path = $rp; Target = (Get-LinkTargetPath $rp) }
    }

    [pscustomobject]@{
        SourcePath        = $src
        SourceName        = $srcName
        DestinationRoot   = $DestinationRoot.TrimEnd('\')
        TargetPath        = $target
        SourceExists      = $exists
        SourceFiles       = $stat.Files
        SourceBytes       = $stat.Bytes
        SourceGB          = [math]::Round($stat.Bytes / 1GB, 3)
        SourceDriveRoot   = $srcRoot
        TargetDriveRoot   = $dstRoot
        SameVolume        = ($srcRoot -and $dstRoot -and ($srcRoot -ieq $dstRoot))
        TargetExists      = (Test-Path -LiteralPath $target)
        TargetFreeBytes   = $free
        RequiredBytes     = $need
        SpaceOk           = ($free -ge 0 -and $free -ge $need)
        ReparsePoints     = $rpDetail
        ReparseCount      = @($rpDetail).Count
    }
}

# ============================================================
#  公开函数 2：Test-MigrationPrerequisite
# ============================================================

function Test-MigrationPrerequisite {
    <#
    .SYNOPSIS
        完整预检。只要有一条 FAIL，就绝不允许执行任何写操作。

    .OUTPUTS
        Pass(bool) / Checks(数组，每项 Name/Level/Message) / Plan

    .EXAMPLE
        (Test-MigrationPrerequisite -Source 'C:\x' -DestinationRoot 'D:\y').Checks | Format-Table
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$DestinationRoot,
        [switch]$Force
    )

    $checks = New-Object System.Collections.ArrayList
    $plan = Get-MigrationPlan -Source $Source -DestinationRoot $DestinationRoot

    # --- 1. Junction 能力探测 ---
    #     真正需要的权限是「能在该卷创建目录联接」，而不是笼统的「管理员」。
    #     实测：NTFS 上创建 Junction 不需要管理员（只有符号链接 /D 才需要），
    #     所以这里直接试建一个 Junction 再删掉，得到的是真实能力而非猜测。
    $capOk = $false; $capMsg = ''
    $probeBase = $null
    if ($plan.SourceExists) { $probeBase = Split-Path $plan.SourcePath -Parent }
    if (-not $probeBase -or -not (Test-Path -LiteralPath $probeBase)) { $probeBase = $env:TEMP }

    $capDir = Join-Path $probeBase ('.__mc_cap_' + [guid]::NewGuid().ToString('N').Substring(0,8))
    $capLnk = Join-Path $probeBase ('.__mc_lnk_' + [guid]::NewGuid().ToString('N').Substring(0,8))
    try {
        New-Item -ItemType Directory -Path $capDir -Force -ErrorAction Stop | Out-Null
        $capOut = cmd.exe /c "mklink /J `"$capLnk`" `"$capDir`"" 2>&1
        $capOk = ($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath $capLnk)
        if (-not $capOk) { $capMsg = ($capOut -join ' ') }
    } catch { $capMsg = $_.Exception.Message }
    if (Test-Path -LiteralPath $capLnk) { $null = cmd.exe /c "rmdir `"$capLnk`"" 2>&1 }
    if (Test-Path -LiteralPath $capDir) { Remove-Item -LiteralPath $capDir -Recurse -Force -ErrorAction SilentlyContinue }

    if ($capOk) {
        [void]$checks.Add((New-Check 'Junction 能力' 'OK' '可在该卷创建目录联接（NTFS 上不需要管理员）'))
    } else {
        [void]$checks.Add((New-Check 'Junction 能力' 'FAIL' "无法创建目录联接，迁移后将缺少链接，程序会找不到文件。请改用管理员身份运行。详情：$capMsg"))
    }

    if (Test-IsAdmin) {
        [void]$checks.Add((New-Check '管理员身份' 'OK' '已具备'))
    } else {
        [void]$checks.Add((New-Check '管理员身份' 'WARN' '当前非管理员：迁移用户目录无影响；若源或目标位于受保护位置可能失败'))
    }

    # --- 2. 源存在且是目录 ---
    if (-not $plan.SourceExists) {
        [void]$checks.Add((New-Check '源目录' 'FAIL' "源目录不存在：$($plan.SourcePath)"))
    } elseif (-not (Get-Item -LiteralPath $plan.SourcePath -Force).PSIsContainer) {
        [void]$checks.Add((New-Check '源目录' 'FAIL' '源路径不是目录'))
    } else {
        [void]$checks.Add((New-Check '源目录' 'OK' "存在，$($plan.SourceGB) GB / $($plan.SourceFiles) 个文件"))
    }

    # --- 3. 源本身不能是重解析点 ---
    if ($plan.SourceExists) {
        $it = Get-Item -LiteralPath $plan.SourcePath -Force -ErrorAction SilentlyContinue
        if ($it -and ($it.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            $t = Get-LinkTargetPath $plan.SourcePath
            if ($t) {
                [void]$checks.Add((New-Check '源类型' 'FAIL' "源已经是链接（-> $t），不能套娃"))
            } else {
                [void]$checks.Add((New-Check '源类型' 'FAIL' '源是重解析点但非链接（云同步/去重占位），不可迁移'))
            }
        } else {
            [void]$checks.Add((New-Check '源类型' 'OK' '普通目录'))
        }
    }

    # --- 4. 黑名单 ---
    $src = $plan.SourcePath
    $blocked = $false
    foreach ($p in $script:HardBlockExact) { if ($src -ieq $p) { $blocked = $true; break } }
    if (-not $blocked) {
        foreach ($p in $script:HardBlockSubtree) {
            if ($src -ieq $p -or $src.StartsWith($p + '\', [StringComparison]::OrdinalIgnoreCase)) { $blocked = $true; break }
        }
    }
    if (-not $blocked) {
        foreach ($f in $script:HardBlockContains) {
            if ($src.IndexOf($f, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $blocked = $true; break }
        }
    }
    if (-not $blocked -and ($src -match '^[A-Za-z]:\\Users\\[^\\]+$')) { $blocked = $true }

    if ($blocked) {
        [void]$checks.Add((New-Check '黑名单' 'FAIL' "受保护路径，任何情况都不允许迁移：$src"))
    } else {
        $soft = $false
        foreach ($p in $script:SoftBlockPrefixes) {
            if ($src -ieq $p -or $src.StartsWith($p + '\', [StringComparison]::OrdinalIgnoreCase)) { $soft = $true; break }
        }
        if ($soft) {
            if ($Force) { [void]$checks.Add((New-Check '黑名单' 'WARN' '程序安装目录，已用 -Force 放行（风险自负）')) }
            else { [void]$checks.Add((New-Check '黑名单' 'FAIL' '程序安装目录子项：迁移可能破坏注册表/服务/更新机制。确认无风险请加 -Force')) }
        } else {
            [void]$checks.Add((New-Check '黑名单' 'OK' '不在任何禁区'))
        }
    }

    # --- 5. 同卷检查 ---
    if ($plan.SameVolume) {
        [void]$checks.Add((New-Check '卷' 'FAIL' "源与目标在同一卷（$($plan.SourceDriveRoot)），同卷搬迁不需要本工具，直接用 Move-Item"))
    } else {
        [void]$checks.Add((New-Check '卷' 'OK' "$($plan.SourceDriveRoot) -> $($plan.TargetDriveRoot)"))
    }

    # --- 6. 目标不能已存在 ---
    if ($plan.TargetExists) {
        [void]$checks.Add((New-Check '目标占用' 'FAIL' "目标已存在，绝不覆盖：$($plan.TargetPath)"))
    } else {
        [void]$checks.Add((New-Check '目标占用' 'OK' "目标可用：$($plan.TargetPath)"))
    }

    # --- 7. 目标父目录必须存在 ---
    $dstParent = $plan.DestinationRoot
    if ($plan.TargetDriveRoot -and (Test-Path -LiteralPath $plan.TargetDriveRoot)) {
        if (Test-Path -LiteralPath $dstParent) {
            [void]$checks.Add((New-Check '目标父目录' 'OK' "存在：$dstParent"))
        } else {
            [void]$checks.Add((New-Check '目标父目录' 'FAIL' "不存在：$dstParent（请先创建）"))
        }
    } else {
        [void]$checks.Add((New-Check '目标父目录' 'FAIL' "目标盘不可用：$($plan.TargetDriveRoot)"))
    }

    # --- 8. 空间 ---
    if ($plan.TargetFreeBytes -lt 0) {
        [void]$checks.Add((New-Check '可用空间' 'FAIL' '无法读取目标盘剩余空间'))
    } elseif ($plan.SpaceOk) {
        [void]$checks.Add((New-Check '可用空间' 'OK' ("需要 {0:N2} GB（含 15% 余量），可用 {1:N2} GB" -f ($plan.RequiredBytes/1GB), ($plan.TargetFreeBytes/1GB))))
    } else {
        [void]$checks.Add((New-Check '可用空间' 'FAIL' ("空间不足：需要 {0:N2} GB，可用 {1:N2} GB" -f ($plan.RequiredBytes/1GB), ($plan.TargetFreeBytes/1GB))))
    }

    # --- 9. 内含重解析点 ---
    if ($plan.ReparseCount -eq 0) {
        [void]$checks.Add((New-Check '内含链接' 'OK' '无重解析点'))
    } else {
        $inside = 0; $outside = 0
        foreach ($rp in $plan.ReparsePoints) {
            if ($rp.Target -and $rp.Target.StartsWith($plan.SourcePath + '\', [StringComparison]::OrdinalIgnoreCase)) { $inside++ }
            else { $outside++ }
        }
        if ($outside -gt 0) {
            [void]$checks.Add((New-Check '内含链接' 'WARN' "发现 $($plan.ReparseCount) 个重解析点，其中 $outside 个指向源目录**外部**：复制会跳过它们，迁移后这些链接将丢失"))
        } else {
            [void]$checks.Add((New-Check '内含链接' 'WARN' "发现 $($plan.ReparseCount) 个指向源目录内部的重解析点：迁移后会按新位置自动重建"))
        }
    }

    # --- 10. SQLite 活跃标记 ---
    if ($plan.SourceExists) {
        $wal = @(Get-ChildItem -LiteralPath $plan.SourcePath -Recurse -Force -File -Filter '*.sqlite-wal' -ErrorAction SilentlyContinue)
        $shm = @(Get-ChildItem -LiteralPath $plan.SourcePath -Recurse -Force -File -Filter '*.sqlite-shm' -ErrorAction SilentlyContinue)
        if ($wal.Count -gt 0 -or $shm.Count -gt 0) {
            [void]$checks.Add((New-Check '运行中程序' 'WARN' "检测到 SQLite 活动标记（$($wal.Count) 个 -wal / $($shm.Count) 个 -shm）：请先**完全退出**对应程序，否则可能损坏数据库"))
        } else {
            [void]$checks.Add((New-Check '运行中程序' 'OK' '未发现 SQLite 活动标记'))
        }
    }

    # --- 11. 占用检测 ---
    if ($plan.SourceExists) {
        $locked = New-Object System.Collections.ArrayList
        $files = @()
        try {
            $files = @(Get-ChildItem -LiteralPath $plan.SourcePath -Recurse -Force -File -ErrorAction SilentlyContinue)
        } catch {}
        foreach ($f in $files) {
            $fs = $null
            try {
                $fs = [System.IO.File]::Open($f.FullName, 'Open', 'Read', 'None')
            } catch {
                [void]$locked.Add($f.FullName)
            } finally { if ($fs) { $fs.Dispose() } }
        }
        if ($locked.Count -gt 0) {
            $sample = (@($locked | Select-Object -First 20) -join "`n    ")
            [void]$checks.Add((New-Check '文件占用' 'FAIL' "有 $($locked.Count) 个文件正被占用，请先退出相关程序：`n    $sample"))
        } else {
            [void]$checks.Add((New-Check '文件占用' 'OK' "已检查 $($files.Count) 个文件，无占用"))
        }
    }

    # --- 12. 源父目录可写（重命名需要） ---
    if ($plan.SourceExists) {
        $srcParent = Split-Path $plan.SourcePath -Parent
        $probe = Join-Path $srcParent ('.__migrate_probe_' + [guid]::NewGuid().ToString('N').Substring(0,8))
        $ok = $false
        try {
            New-Item -ItemType File -Path $probe -Force | Out-Null
            Remove-Item -LiteralPath $probe -Force
            $ok = $true
        } catch {}
        if ($ok) { [void]$checks.Add((New-Check '源可写' 'OK' "源父目录可写：$srcParent")) }
        else { [void]$checks.Add((New-Check '源可写' 'FAIL' "源父目录不可写，无法重命名：$srcParent")) }
    }

    # --- 13. 目标可写 ---
    if (Test-Path -LiteralPath $plan.DestinationRoot) {
        $probe = Join-Path $plan.DestinationRoot ('.__migrate_probe_' + [guid]::NewGuid().ToString('N').Substring(0,8))
        $ok = $false
        try {
            New-Item -ItemType Directory -Path $probe -Force | Out-Null
            Remove-Item -LiteralPath $probe -Recurse -Force
            $ok = $true
        } catch {}
        if ($ok) { [void]$checks.Add((New-Check '目标可写' 'OK' "目标目录可写：$($plan.DestinationRoot)")) }
        else { [void]$checks.Add((New-Check '目标可写' 'FAIL' "目标目录不可写：$($plan.DestinationRoot)")) }
    }

    $checks = @($checks)
    $fail = @($checks | Where-Object { $_.Level -eq 'FAIL' })
    $warn = @($checks | Where-Object { $_.Level -eq 'WARN' })

    [pscustomobject]@{
        Pass        = ($fail.Count -eq 0)
        FailCount   = $fail.Count
        WarnCount   = $warn.Count
        Checks      = $checks
        Plan        = $plan
    }
}

# ============================================================
#  公开函数 3：Start-DirectoryMigration
# ============================================================

function Start-DirectoryMigration {
    <#
    .SYNOPSIS
        执行迁移：复制 -> 校验 -> 原子切换（重命名/建链接/删残留）。

    .DESCRIPTION
        严格顺序，任何一步失败都不会破坏源目录：
          1. 完整预检
          2. 写 manifest
          3. robocopy 复制（/XJ 跳过重解析点；退出码 0-7 视为成功）
          4. 校验文件数与字节数（不通过绝不删源）
          5. 原子切换：Rename 源 -> mklink /J -> 验证 -> 删除残留
          6. 重建源目录内部的重解析点

    .PARAMETER Source
        要迁移的目录

    .PARAMETER DestinationRoot
        目标盘父目录

    .PARAMETER Force
        放行「程序安装目录」等软禁区，必须同时提供 -ForceReason

    .PARAMETER ForceReason
        放行软禁区的理由，会写进 manifest 存档

    .PARAMETER ProgressCallback
        进度回调，参数为一个对象：Step / Current / Total / Message

    .PARAMETER ManifestDir
        manifest 与日志的存放目录，默认 %TEMP%

    .EXAMPLE
        Start-DirectoryMigration -Source 'C:\Users\me\AppData\Local\JetBrains' -DestinationRoot 'D:\moved'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$DestinationRoot,
        [switch]$Force,
        [string]$ForceReason,
        [scriptblock]$ProgressCallback,
        [string]$ManifestDir = $env:TEMP
    )

    $t0 = Get-Date
    $src = $Source.TrimEnd('\')

    $result = [pscustomobject]@{
        Success = $false; SourcePath = $src; TargetPath = ''
        CopiedFiles = 0; CopiedBytes = [int64]0; DurationSeconds = 0
        LogPath = ''; ManifestPath = ''; ErrorMessage = ''; RollbackHint = ''
    }

    # ---------- 步骤 1：预检 ----------
    Invoke-Progress $ProgressCallback '预检' 0 1 '正在执行完整预检…'
    $pre = Test-MigrationPrerequisite -Source $src -DestinationRoot $DestinationRoot -Force:$Force
    if (-not $pre.Pass) {
        $msgs = @($pre.Checks | Where-Object { $_.Level -eq 'FAIL' } | ForEach-Object { $_.Message })
        $result.ErrorMessage = "预检未通过：`n  - " + ($msgs -join "`n  - ")
        $result.DurationSeconds = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
        return $result
    }

    if ($Force -and -not $ForceReason) {
        $result.ErrorMessage = '使用 -Force 放行软禁区时必须提供 -ForceReason 说明理由（会记入 manifest 存档）'
        $result.DurationSeconds = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
        return $result
    }

    $plan   = $pre.Plan
    $target = $plan.TargetPath
    $result.TargetPath = $target

    # ---------- 步骤 2：manifest ----------
    if (-not (Test-Path -LiteralPath $ManifestDir)) { New-Item -ItemType Directory -Path $ManifestDir -Force | Out-Null }
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $safeName = ($plan.SourceName -replace '[\\/:*?"<>|]', '_')
    $manifestPath = Join-Path $ManifestDir "migrate-$safeName-$stamp.json"
    $logPath = Join-Path $ManifestDir "migrate-$safeName-$stamp.robocopy.log"

    $bakName = "$($plan.SourceName).__migrating_$stamp"
    $bakPath = Join-Path (Split-Path $src -Parent) $bakName

    $manifest = [pscustomobject]@{
        Version         = $script:ManifestVersion
        Phase           = 'Prepared'
        SourcePath      = $src
        TargetPath      = $target
        DestinationRoot = $DestinationRoot.TrimEnd('\')
        BackupPath      = $bakPath
        StartedAt       = $t0.ToString('yyyy-MM-dd HH:mm:ss')
        FinishedAt      = ''
        SourceFiles     = $plan.SourceFiles
        SourceBytes     = $plan.SourceBytes
        CopiedFiles     = 0
        CopiedBytes     = [int64]0
        ReparsePoints   = @($plan.ReparsePoints)
        Force           = [bool]$Force
        ForceReason     = $ForceReason
        RobocopyLog     = $logPath
        ErrorMessage    = ''
        Steps           = @()
    }
    Add-Step $manifest '预检' $true "通过（WARN $($pre.WarnCount) 条）"
    Write-Manifest -Manifest $manifest -Path $manifestPath

    $result.ManifestPath = $manifestPath
    $result.LogPath = $logPath
    $result.RollbackHint = "回滚命令：Undo-DirectoryMigration -ManifestPath '$manifestPath'"

    try {
        # ---------- 步骤 3：复制 ----------
        Invoke-Progress $ProgressCallback '复制' 0 $plan.SourceFiles 'robocopy 复制中…'
        $rc = Get-RobocopyPath
        $dstParent = $DestinationRoot.TrimEnd('\')

        # 先建目标父目录下的最终目录（robocopy 自己会建，但显式一点便于排错）
        if (-not (Test-Path -LiteralPath $target)) { New-Item -ItemType Directory -Path $target -Force | Out-Null }

        $rcArgs = @(
            "`"$src`"", "`"$target`"",
            '/E', '/COPY:DAT', '/DCOPY:DAT', '/R:1', '/W:1', '/XJ', '/NP', '/NDL', '/NJH', '/NJS',
            "/LOG:`"$logPath`""
        )
        $rcCode = Invoke-RobocopyExe -Arguments $rcArgs -ProgressLog $logPath -TotalFiles ([int]$plan.SourceFiles) `
            -OnTick { param($done, $total) Invoke-Progress $ProgressCallback '复制' $done $total 'robocopy 复制中…' }

        # robocopy 退出码是位标志：0-7 全部表示成功，>=8 才是真的失败。
        # 读不到退出码（$null）或为负（如被强杀）一律按失败处理，绝不能当成成功。
        if ($null -eq $rcCode -or $rcCode -ge 8 -or $rcCode -lt 0) {
            throw "robocopy 失败，退出码 [$rcCode]（0-7 为成功，>=8 或读不到均为失败）。详见日志：$logPath"
        }
        Add-Step $manifest '复制' $true "robocopy 退出码 $rcCode（视为成功）"
        $manifest.Phase = 'Copied'
        Write-Manifest -Manifest $manifest -Path $manifestPath

        # ---------- 步骤 4：校验 ----------
        Invoke-Progress $ProgressCallback '校验' 0 1 '校验文件数与字节数…'
        $tgtStat = Get-DirStat -Path $target
        $manifest.CopiedFiles = $tgtStat.Files
        $manifest.CopiedBytes = $tgtStat.Bytes

        if ($tgtStat.Files -ne $plan.SourceFiles -or $tgtStat.Bytes -ne $plan.SourceBytes) {
            throw ("校验不通过，拒绝删除源目录。`n" +
                   "  源  : $($plan.SourceFiles) 个文件 / $($plan.SourceBytes) 字节`n" +
                   "  目标: $($tgtStat.Files) 个文件 / $($tgtStat.Bytes) 字节`n" +
                   "源目录与已复制的内容都保持原样，可手动核对后重新迁移。")
        }
        Add-Step $manifest '校验' $true "$($tgtStat.Files) 个文件 / $($tgtStat.Bytes) 字节，完全一致"
        $manifest.Phase = 'Verified'
        Write-Manifest -Manifest $manifest -Path $manifestPath

        # ---------- 步骤 5：原子切换 ----------
        Invoke-Progress $ProgressCallback '切换' 0 1 '重命名源目录（毫秒级）…'
        if (Test-Path -LiteralPath $bakPath) { throw "备份名已存在，请稍后重试：$bakPath" }

        # 目录被打开的文件占用时重命名会失败，而这类占用常常是瞬时的
        # （程序在预检通过之后又打开了文件），所以退避重试几次。
        $renamed = $false; $lastErr = $null
        for ($try = 1; $try -le 5; $try++) {
            try { Rename-Item -LiteralPath $src -NewName $bakName -ErrorAction Stop; $renamed = $true; break }
            catch { $lastErr = $_; Start-Sleep -Milliseconds (400 * $try) }
        }
        if (-not $renamed) {
            throw ("无法重命名源目录：$src`n" +
                   "系统回报：$($lastErr.Exception.Message)`n`n" +
                   "最常见原因：该目录下的文件正被程序打开（IDE / 聊天工具 / 输入法等仍在运行）。`n" +
                   "处理办法：完全退出相关程序（含系统托盘图标）后重试。`n`n" +
                   "数据无损失：源目录保持原样；目标位置可能已有一份完整副本（见 RollbackHint）。")
        }
        Add-Step $manifest '重命名源' $true "$src -> $bakPath"
        $manifest.Phase = 'Renamed'
        Write-Manifest -Manifest $manifest -Path $manifestPath

        Invoke-Progress $ProgressCallback '切换' 0 1 '创建 Junction…'
        $mkOut = cmd.exe /c "mklink /J `"$src`" `"$target`"" 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw ("创建 Junction 失败（mklink 退出码 $LASTEXITCODE）：$mkOut`n" +
                   "数据已完整位于 $target，源目录暂时叫 $bakPath。`n" +
                   "可用 Undo-DirectoryMigration 一键恢复，或手动执行：`n  mklink /J `"$src`" `"$target`"")
        }
        Add-Step $manifest '建链接' $true ($mkOut -join ' ')

        # 验证链接可访问
        Invoke-Progress $ProgressCallback '切换' 0 1 '验证链接…'
        $linkItem = Get-Item -LiteralPath $src -Force -ErrorAction SilentlyContinue
        if (-not $linkItem -or -not ($linkItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            throw "Junction 验证失败：$src 不是重解析点。数据在 $target，备份在 $bakPath"
        }
        $probeFile = Get-ChildItem -LiteralPath $src -Recurse -Force -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($probeFile) {
            $fs = $null
            try { $fs = [System.IO.File]::OpenRead($probeFile.FullName) }
            catch { throw "Junction 已建立，但通过原路径读取文件失败：$($probeFile.FullName)" }
            finally { if ($fs) { $fs.Dispose() } }
        }
        Add-Step $manifest '验证链接' $true '链接可访问'
        $manifest.Phase = 'Switched'
        Write-Manifest -Manifest $manifest -Path $manifestPath

        # ---------- 步骤 6：重建源内部的相对重解析点 ----------
        $rebuilt = 0; $skippedRp = 0
        foreach ($rp in @($plan.ReparsePoints)) {
            $t = [string]$rp.Target
            if (-not $t) { continue }
            $relFromSrc = $null
            if ($t.StartsWith($src + '\', [StringComparison]::OrdinalIgnoreCase)) {
                $relFromSrc = $t.Substring($src.Length + 1)
            } elseif ($t.StartsWith($plan.SourcePath + '\', [StringComparison]::OrdinalIgnoreCase)) {
                $relFromSrc = $t.Substring($plan.SourcePath.Length + 1)
            }
            if (-not $relFromSrc) { $skippedRp++; continue }

            $relOfLink = $rp.Path.Substring($src.Length + 1)
            $newLinkPath = Join-Path $target $relOfLink
            $newTgtPath  = Join-Path $target $relFromSrc
            if (-not (Test-Path -LiteralPath $newTgtPath)) { $skippedRp++; continue }
            if (Test-Path -LiteralPath $newLinkPath) { $skippedRp++; continue }
            try {
                $null = cmd.exe /c "mklink /J `"$newLinkPath`" `"$newTgtPath`"" 2>&1
                if ($LASTEXITCODE -eq 0) { $rebuilt++ } else { $skippedRp++ }
            } catch { $skippedRp++ }
        }
        if ($rebuilt -gt 0 -or $skippedRp -gt 0) {
            Add-Step $manifest '重建内部链接' $true "重建 $rebuilt 个，跳过 $skippedRp 个"
        }

        # ---------- 步骤 7：删除残留 ----------
        Invoke-Progress $ProgressCallback '清理' 0 1 '删除原目录残留…'
        try {
            # 先摘掉残留里的重解析点（只删链接本身，绝不跟进），避免递归删除误伤链接目标
            $bakReparse = @(Get-ChildItem -LiteralPath $bakPath -Recurse -Force -Directory -ErrorAction SilentlyContinue |
                            Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint })
            foreach ($rp in $bakReparse) {
                $null = cmd.exe /c "rmdir `"$($rp.FullName)`"" 2>&1
            }
            Remove-Item -LiteralPath $bakPath -Recurse -Force -ErrorAction Stop
            Add-Step $manifest '清理残留' $true '已删除'
        } catch {
            # 这一步失败不算迁移失败：链接已生效、程序已能正常打开
            Add-Step $manifest '清理残留' $false $_.Exception.Message
            $manifest.ErrorMessage = "迁移已成功，但残留目录未能删除：$bakPath（可稍后手动删除）"
        }

        $manifest.Phase = 'Completed'
        $manifest.FinishedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Write-Manifest -Manifest $manifest -Path $manifestPath

        $result.Success = $true
        $result.CopiedFiles = $tgtStat.Files
        $result.CopiedBytes = $tgtStat.Bytes
        $result.ErrorMessage = $manifest.ErrorMessage
        Invoke-Progress $ProgressCallback '完成' 1 1 '迁移完成'
    }
    catch {
        $manifest.ErrorMessage = $_.Exception.Message
        $manifest.Phase = 'Failed'
        $manifest.FinishedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Add-Step $manifest '失败' $false $_.Exception.Message
        try { Write-Manifest -Manifest $manifest -Path $manifestPath } catch {}

        $result.ErrorMessage = $_.Exception.Message

        # 若目标位置已经留下一份副本，明确告诉用户，并给出清理方式
        if (Test-Path -LiteralPath $target) {
            $orphanStat = Get-DirStat -Path $target
            $result.RollbackHint = ("回滚/清理命令：`n  Undo-DirectoryMigration -ManifestPath '$manifestPath' -CleanOrphanTarget`n" +
                ("注意：目标位置 $target 已有一份副本（{0:N2} GB / {1} 个文件，与源一致）。" -f ($orphanStat.Bytes / 1GB), $orphanStat.Files))
        }
        Invoke-Progress $ProgressCallback '失败' 0 1 $_.Exception.Message
    }

    $result.DurationSeconds = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
    return $result
}

# ============================================================
#  公开函数 4：Undo-DirectoryMigration
# ============================================================

function Undo-DirectoryMigration {
    <#
    .SYNOPSIS
        回滚。按代价从低到高自动选择方案：重命名回滚 > 补建链接 > 完整搬回。

    .DESCRIPTION
        方案 A 重命名回滚：原位置有 .__migrating_* 残留 -> 改回原名，零数据移动
        方案 B 断链修复  ：目标完整但原位置没有链接   -> 补建链接，零数据移动
        方案 C 完整搬回  ：链接已生效、用户就是想撤销  -> 搬回全部数据

    .PARAMETER ManifestPath
        Start-DirectoryMigration 生成的 manifest 路径

    .PARAMETER Method
        强制指定方案 A / B / C；省略则自动判断
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ManifestPath,
        [ValidateSet('Auto', 'A', 'B', 'C', 'D')][string]$Method = 'Auto',
        [switch]$CleanOrphanTarget
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $m = Read-Manifest -Path $ManifestPath

    $src = [string]$m.SourcePath
    $target = [string]$m.TargetPath
    $result = [pscustomobject]@{
        Success = $false; Method = ''; MethodName = ''; Reason = ''
        SourcePath = $src; TargetPath = $target
        ElapsedMs = 0; MovedBytes = [int64]0; ErrorMessage = ''
        OrphanPath = ''; OrphanBytes = [int64]0; OrphanRemoved = $false
    }

    $srcParent = Split-Path $src -Parent
    $srcName = Split-Path $src -Leaf

    # 探测当前实际状态
    $srcExists = Test-Path -LiteralPath $src
    $srcIsLink = $false
    if ($srcExists) {
        $it = Get-Item -LiteralPath $src -Force -ErrorAction SilentlyContinue
        if ($it -and ($it.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { $srcIsLink = $true }
    }
    $bakDirs = @()
    if ($srcParent -and (Test-Path -LiteralPath $srcParent)) {
        $bakDirs = @(Get-ChildItem -LiteralPath $srcParent -Force -Directory -ErrorAction SilentlyContinue |
                     Where-Object { $_.Name -like "$srcName.__migrating_*" })
    }
    $targetExists = Test-Path -LiteralPath $target

    try {
        # ---------- 自动选择方案 ----------
        if ($Method -eq 'Auto') {
            if ($bakDirs.Count -gt 0 -and -not $srcIsLink) { $Method = 'A' }
            elseif (-not $srcExists -and $targetExists) { $Method = 'B' }
            elseif ($srcIsLink) { $Method = 'C' }
            elseif ($srcExists -and $targetExists) {
                # 源完好、目标留有一份副本 —— 典型是「复制成功后卡在重命名/建链接」后回滚的结果
                $Method = 'D'
            }
            else { throw "无法判断当前状态：源存在=$srcExists 是链接=$srcIsLink 备份残留=$($bakDirs.Count) 目标存在=$targetExists" }
        }
        $result.Method = $Method

        # ---------- 方案 A：重命名回滚（零数据移动） ----------
        if ($Method -eq 'A') {
            if ($bakDirs.Count -eq 0) { throw '方案 A 不适用：找不到 .__migrating_* 残留目录' }
            if ($srcExists) { throw "方案 A 不适用：原位置已被占用（$src）" }
            $bak = $bakDirs[0].FullName
            Rename-Item -LiteralPath $bak -NewName $srcName -ErrorAction Stop
            $result.Success = $true
            $result.MethodName = '重命名回滚（零数据移动）'
            $result.Reason = "把 $bak 改回原名"
        }
        # ---------- 方案 B：补建链接（零数据移动） ----------
        elseif ($Method -eq 'B') {
            if ($srcExists) { throw "方案 B 不适用：原位置已被占用（$src）" }
            if (-not $targetExists) { throw "方案 B 不适用：目标不存在（$target）" }
            $out = cmd.exe /c "mklink /J `"$src`" `"$target`"" 2>&1
            if ($LASTEXITCODE -ne 0) { throw "补建链接失败：$out" }
            $result.Success = $true
            $result.MethodName = '补建链接（零数据移动）'
            $result.Reason = "原位置缺链接，已补上 -> $target"
        }
        # ---------- 方案 D：源完好 + 目标有副本 -> 只清理副本（零数据移动）----------
        elseif ($Method -eq 'D') {
            if (-not $srcExists) { throw "方案 D 不适用：源目录不存在（$src）" }
            if (-not $targetExists) { throw "方案 D 不适用：目标不存在（$target）" }
            if ($srcIsLink) { throw "方案 D 不适用：源是链接，请用方案 C" }

            # 删除前先核对目标确实是「我们那次复制出来的副本」：
            # 与 manifest 记录的文件数/字节数比对，对不上就拒绝删除，避免误删未知数据。
            $tgtStat = Get-DirStat -Path $target
            $expFiles = [int64]$m.CopiedFiles
            $expBytes = [int64]$m.CopiedBytes
            if ($expFiles -gt 0 -and $tgtStat.Files -ne $expFiles) {
                throw ("拒绝清理：目标文件数与 manifest 记录不符`n" +
                       "  manifest 记录 $expFiles 个，实际 $($tgtStat.Files) 个`n" +
                       "  目标 $target 可能不是本工具复制的副本，请人工确认后再处理")
            }
            if ($expBytes -gt 0 -and $tgtStat.Bytes -ne $expBytes) {
                throw ("拒绝清理：目标字节数与 manifest 记录不符`n" +
                       "  manifest 记录 $expBytes 字节，实际 $($tgtStat.Bytes) 字节`n" +
                       "  目标 $target 可能不是本工具复制的副本，请人工确认后再处理")
            }

            # 源目录存在即视为已恢复；这里只负责清掉那份等量副本
            $result.OrphanPath  = $target
            $result.OrphanBytes = $tgtStat.Bytes
            if (-not $CleanOrphanTarget) {
                $result.Success = $false
                $result.MethodName = '仅检测（未清理）'
                # 注意：-f 的优先级高于 +，必须把整段拼接括起来，否则 {0} 不会被替换
                $result.Reason = ("源目录完好，目标位置留有一份 {0:N2} GB 的副本。`n确认无需保留后，加 -CleanOrphanTarget 重新执行即可清理。" -f ($tgtStat.Bytes / 1GB))
            } else {
                Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
                $result.OrphanRemoved = $true
                $result.Success = $true
                $result.MethodName = '清理孤儿副本（零数据移动）'
                $result.Reason = "源目录完好未动；已删除目标位置的等价副本"
                $result.MovedBytes = [int64]0
                $tParent = Split-Path $target -Parent
                if ($tParent -and (Test-Path -LiteralPath $tParent)) {
                    $left = @(Get-ChildItem -LiteralPath $tParent -Force -ErrorAction SilentlyContinue)
                    if ($left.Count -eq 0) { Remove-Item -LiteralPath $tParent -Force -ErrorAction SilentlyContinue }
                }
            }
        }
        # ---------- 方案 C：完整搬回 ----------
        else {
            if (-not $srcIsLink) {
                if ($srcExists) { throw "方案 C 不适用：$src 不是链接，拒绝在非链接目录上操作" }
            } else {
                # 只删链接本身，绝不跟进 —— 用 rmdir 而不是 Remove-Item -Recurse
                $out = cmd.exe /c "rmdir `"$src`"" 2>&1
                if ($LASTEXITCODE -ne 0) { throw "移除链接失败：$out" }
            }
            if (-not $targetExists) { throw "方案 C 不适用：目标不存在（$target）" }

            # 重建源父目录（如果它随链接一起没了）
            if (-not (Test-Path -LiteralPath $srcParent)) { New-Item -ItemType Directory -Path $srcParent -Force | Out-Null }

            $log = Join-Path $env:TEMP ("undo-" + [guid]::NewGuid().ToString('N').Substring(0,8) + ".log")
            $rcArgs = @("`"$target`"", "`"$src`"", '/E', '/COPY:DAT', '/DCOPY:DAT', '/R:1', '/W:1', '/XJ', '/MOVE',
                        '/NP', '/NDL', '/NJH', '/NJS', "/LOG:`"$log`"")
            $undoCode = Invoke-RobocopyExe -Arguments $rcArgs -ProgressLog $log
            if ($null -eq $undoCode -or $undoCode -ge 8 -or $undoCode -lt 0) {
                throw "搬回失败，robocopy 退出码 [$undoCode]，日志：$log"
            }

            # 校验
            $backStat = Get-DirStat -Path $src
            if ([int64]$m.SourceFiles -gt 0 -and $backStat.Files -ne [int64]$m.SourceFiles) {
                $result.ErrorMessage = "已搬回，但文件数不一致（期望 $($m.SourceFiles)，实际 $($backStat.Files)），请手动核对"
            }
            # 清理目标残留空目录
            if (Test-Path -LiteralPath $target) {
                $left = @(Get-ChildItem -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue)
                if ($left.Count -eq 0) { Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue }
            }
            $result.Success = $true
            $result.MethodName = '完整搬回（需移动全部数据）'
            $result.Reason = "从 $target 搬回 $src"
            $result.MovedBytes = $backStat.Bytes
        }

        # 方案 A / B 只把源恢复原状，不会删掉已复制到目标的那份副本 ——
        # 这里检测并（在显式要求时）清理，否则会在目标盘白占一份等量空间。
        if ($result.Success -and $targetExists -and $Method -ne 'D') {
            $orphanStat = Get-DirStat -Path $target
            $result.OrphanPath  = $target
            $result.OrphanBytes = $orphanStat.Bytes
            if ($CleanOrphanTarget) {
                try {
                    Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
                    $result.OrphanRemoved = $true
                    # 目标父目录空了就顺手删掉
                    $tParent = Split-Path $target -Parent
                    if ($tParent -and (Test-Path -LiteralPath $tParent)) {
                        $left = @(Get-ChildItem -LiteralPath $tParent -Force -ErrorAction SilentlyContinue)
                        if ($left.Count -eq 0) { Remove-Item -LiteralPath $tParent -Force -ErrorAction SilentlyContinue }
                    }
                } catch {
                    $result.OrphanRemoved = $false
                    $result.ErrorMessage = "源已恢复，但目标副本清理失败：$($_.Exception.Message)"
                }
            }
        }

        # 更新 manifest 状态
        try {
            $m.Phase = 'RolledBack'
            Add-Step $m '回滚' $true "方案 $Method：$($result.MethodName)"
            Write-Manifest -Manifest $m -Path $ManifestPath
        } catch {}
    }
    catch {
        $result.ErrorMessage = $_.Exception.Message
    }

    $sw.Stop()
    $result.ElapsedMs = $sw.ElapsedMilliseconds
    return $result
}

Export-ModuleMember -Function Get-MigrationPlan, Test-MigrationPrerequisite, Start-DirectoryMigration, Undo-DirectoryMigration
