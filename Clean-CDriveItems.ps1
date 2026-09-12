#Requires -Version 5.1
<#
.SYNOPSIS
    清理队列执行器 —— 供 GUI 以独立进程调用

.DESCRIPTION
    对「可删 DELETE」类目录执行清理。两种模式：
      Recycle    移入回收站（可恢复，默认）
      Permanent  永久删除（不可恢复）

    安全设计（四层）：
      1) 调用方（GUI）已过滤 —— 只把 FinalVerdict=DELETE 的项放进来
      2) 本执行器**独立再过滤一次** —— 不信任调用方
      3) 硬禁区名单 —— 盘符根、Windows、Program Files、用户主目录、回收站等一律拒绝
      4) 重解析点只删链接本身（rmdir），绝不递归跟进到链接目标

.NOTES
    每一层都是独立的，任何一层拦下都会跳过该项并记录原因。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QueuePath,
    [Parameter(Mandatory)][string]$ResultPath,
    [Parameter(Mandatory)][string]$LogDir,
    [ValidateSet('Recycle', 'Permanent')][string]$Mode = 'Recycle',
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$SD = $env:SystemDrive

if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

# ============================================================
#  硬禁区：清理动作自己再挡一层
# ============================================================
$script:BlockExact = @(
    "$SD", "$SD\"
    "$SD\Windows", "$SD\Program Files", "$SD\Program Files (x86)", "$SD\ProgramData"
    "$SD\Users", "$SD\Recovery", "$SD\PerfLogs", "$SD\Boot", "$SD\inetpub"
    "$SD\`$Recycle.Bin", "$SD\System Volume Information"
    "$env:USERPROFILE", "$env:LOCALAPPDATA", "$env:APPDATA", "$env:ProgramData"
)
# 注意：这里**不能**放 "$SD\Users" —— 那会连
# C:\Users\<用户>\AppData\Local\pip 这类本该可清理的缓存一并封死。
# 用户主目录本身由上面的 BlockExact 精确拦下即可。
$script:BlockSubtree = @(
    "$SD\Windows"
    "$SD\Program Files"
    "$SD\Program Files (x86)"
    "$SD\`$Recycle.Bin"
    "$SD\System Volume Information"
    "$SD\Recovery"
    "$SD\PerfLogs"
)

function Test-CleanBlocked {
    param([string]$Path)
    $p = $Path.TrimEnd('\')
    foreach ($b in $script:BlockExact) { if ($p -ieq $b.TrimEnd('\')) { return "受保护路径，禁止清理：$p" } }
    foreach ($b in $script:BlockSubtree) {
        if ($p -ieq $b -or $p.StartsWith($b + '\', [StringComparison]::OrdinalIgnoreCase)) {
            return "位于受保护目录下，禁止清理：$p"
        }
    }
    if ($p -match '^[A-Za-z]:$') { return "驱动器根目录，禁止清理：$p" }
    return ''
}

function Get-DirSizeBytes {
    param([string]$Path)
    $bytes = [int64]0
    $stack = New-Object System.Collections.Stack
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $cur = $stack.Pop()
        try {
            $di = New-Object System.IO.DirectoryInfo $cur
            foreach ($f in $di.EnumerateFiles()) { try { $bytes += $f.Length } catch {} }
            foreach ($sd in $di.EnumerateDirectories()) {
                try {
                    if ($sd.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
                    $stack.Push($sd.FullName)
                } catch {}
            }
        } catch {}
    }
    return $bytes
}

function Remove-OneItem {
    <#
    .SYNOPSIS
        删除单个路径。重解析点只删链接；其余按模式删除。
    #>
    param([string]$Path, [string]$Mode)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return @{ Ok = $true; Bytes = 0; Note = '路径已不存在，跳过' } }

    $isLink = [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
    if ($isLink) {
        # 链接只能删链接本身 —— 用 rmdir，绝不加 /S，否则会跟进删除目标盘的真实数据
        $out = cmd.exe /c "rmdir `"$Path`"" 2>&1
        if ($LASTEXITCODE -eq 0) { return @{ Ok = $true; Bytes = 0; Note = '已移除链接本身（链接目标未受影响）' } }
        return @{ Ok = $false; Bytes = 0; Note = "移除链接失败：$out" }
    }

    $size = if ($item.PSIsContainer) { Get-DirSizeBytes $Path } else { [int64]$item.Length }

    if ($Mode -eq 'Recycle') {
        try {
            Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop
            if ($item.PSIsContainer) {
                [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory(
                    $Path,
                    [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                    [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
            } else {
                [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
                    $Path,
                    [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                    [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
            }
            return @{ Ok = $true; Bytes = $size; Note = '已移入回收站' }
        } catch {
            return @{ Ok = $false; Bytes = 0; Note = "移入回收站失败：$($_.Exception.Message)" }
        }
    }

    # 永久删除
    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        return @{ Ok = $true; Bytes = $size; Note = '已永久删除' }
    } catch {
        return @{ Ok = $false; Bytes = 0; Note = "删除失败：$($_.Exception.Message)" }
    }
}

# ============================================================
#  主流程
# ============================================================
$queue = Get-Content -LiteralPath $QueuePath -Raw -Encoding UTF8 | ConvertFrom-Json
$items = @($queue.Items)

Write-Host ""
Write-Host ("=" * 74)
Write-Host (" 清理队列   模式 = $(if ($Mode -eq 'Recycle') { '移入回收站（可恢复）' } else { '永久删除（不可恢复）' })$(if ($DryRun) { '   [试运行]' })")
Write-Host (" 共 {0} 项   开始时间 {1}" -f $items.Count, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Write-Host ("=" * 74)

$results = New-Object System.Collections.ArrayList
$done = 0; $failed = 0; $skipped = 0; $freedBytes = [int64]0

foreach ($it in $items) {
    $p = [string]$it.Path
    if (-not $p) { continue }

    Write-Host ""
    Write-Host ("  $p")

    # 第二层：执行器自己再挡一次
    $blocked = Test-CleanBlocked -Path $p
    if ($blocked) {
        Write-Host ("    [跳过] $blocked")
        $skipped++
        [void]$results.Add([pscustomobject]@{ Path=$p; Success=$false; Phase='Blocked'; Bytes=[int64]0; Note=$blocked })
        continue
    }

    if ($DryRun) {
        $sz = 0
        $ex = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
        if ($ex -and $ex.PSIsContainer) { $sz = Get-DirSizeBytes $p } elseif ($ex) { $sz = [int64]$ex.Length }
        Write-Host ("    [试运行] 将{0}  {1:N1} MB" -f $(if ($Mode -eq 'Recycle') { '移入回收站' } else { '永久删除' }), ($sz/1MB))
        $done++
        [void]$results.Add([pscustomobject]@{ Path=$p; Success=$true; Phase='DryRun'; Bytes=$sz; Note='试运行未实际执行' })
        continue
    }

    $r = Remove-OneItem -Path $p -Mode $Mode
    if ($r.Ok) {
        Write-Host ("    [成功] {0}  释放 {1:N1} MB" -f $r.Note, ($r.Bytes/1MB))
        $done++
        $freedBytes += $r.Bytes
        [void]$results.Add([pscustomobject]@{ Path=$p; Success=$true; Phase='Cleaned'; Bytes=$r.Bytes; Note=$r.Note })
    } else {
        Write-Host ("    [失败] {0}" -f $r.Note)
        $failed++
        [void]$results.Add([pscustomobject]@{ Path=$p; Success=$false; Phase='Failed'; Bytes=[int64]0; Note=$r.Note })
    }
}

$results = @($results)
$out = [pscustomobject]@{
    Mode       = $Mode
    DryRun     = [bool]$DryRun
    FinishedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Total      = $items.Count
    Done       = $done
    Failed     = $failed
    Skipped    = $skipped
    FreedBytes = $freedBytes
    Results    = $results
}
$out | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ResultPath -Encoding UTF8

# 追加一份操作日志（留痕）
try {
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $logPath = Join-Path $LogDir "cleanup-$stamp.json"
    $out | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $logPath -Encoding UTF8
} catch {}

Write-Host ""
Write-Host ("=" * 74)
if ($DryRun) {
    Write-Host (" 试运行结束：可处理 {0} 项，预计释放 {1:N2} GB" -f $done, ($freedBytes/1GB))
} else {
    Write-Host (" 清理结束：成功 {0} / 失败 {1} / 跳过 {2} / 共 {3}" -f $done, $failed, $skipped, $items.Count)
    Write-Host (" 已释放 {0:N2} GB" -f ($freedBytes/1GB))
    if ($Mode -eq 'Recycle') { Write-Host " 提示：内容已移入回收站，清空回收站才会真正释放磁盘空间。" }
}
Write-Host ("=" * 74)
Write-Host ""
