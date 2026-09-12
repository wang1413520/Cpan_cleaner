#Requires -Version 5.1
<#
.SYNOPSIS
    迁移队列执行器 —— 供 GUI 以独立进程调用

.DESCRIPTION
    读取队列 JSON，逐项执行「预检 -> 迁移」或「回滚」，并实时写出：
      · 人类可读日志（由 GUI 重定向捕获并流式显示）
      · progress.json（机器可读进度，GUI 轮询）
      · result.json（最终逐项结果，GUI 用来展示和回滚）

    单独立运行也可以：
      Invoke-MigrationQueue.ps1 -QueuePath q.json -ProgressPath p.json -ResultPath r.json -Mode Preflight

.NOTES
    有意不暴露 -Force：GUI 走保守路线，软禁区（Program Files）一律跳过。
    确有需要请直接用 MigrateCore 的命令行接口。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QueuePath,
    [Parameter(Mandatory)][string]$ProgressPath,
    [Parameter(Mandatory)][string]$ResultPath,
    [ValidateSet('Preflight', 'Migrate', 'Undo')][string]$Mode = 'Migrate',
    [string]$ManifestDir = (Join-Path $env:TEMP 'cdrive-migrate-manifests')
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$ModulePath = Join-Path $PSScriptRoot 'MigrateCore.psm1'
if (-not (Test-Path -LiteralPath $ModulePath)) { throw "找不到 MigrateCore.psm1：$ModulePath" }
Import-Module $ModulePath -Force

if (-not (Test-Path -LiteralPath $ManifestDir)) { New-Item -ItemType Directory -Path $ManifestDir -Force | Out-Null }

function Write-Prog {
    param([int]$Index, [int]$Total, [string]$Source, [string]$Phase, [int]$Percent, [int]$Done, [int]$Failed)
    $o = [pscustomobject]@{
        Index = $Index; Total = $Total; Source = $Source; Phase = $Phase
        Percent = $Percent; Done = $Done; Failed = $Failed
        At = (Get-Date).ToString('HH:mm:ss')
    }
    try { $o | ConvertTo-Json -Compress | Set-Content -LiteralPath $ProgressPath -Encoding UTF8 } catch {}
}

$queue = Get-Content -LiteralPath $QueuePath -Raw -Encoding UTF8 | ConvertFrom-Json
$items = @($queue.Items)
$targetRootDefault = [string]$queue.DestinationRoot

Write-Host ""
Write-Host ("=" * 74)
Write-Host (" 迁移队列执行器   模式 = $Mode   共 $($items.Count) 项")
Write-Host (" 开始时间 " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Write-Host ("=" * 74)

$results = New-Object System.Collections.ArrayList
$done = 0; $failed = 0; $skipped = 0
$idx = 0

foreach ($it in $items) {
    $idx++
    $src  = [string]$it.Source
    $root = if ($it.DestinationRoot) { [string]$it.DestinationRoot } else { $targetRootDefault }

    Write-Host ""
    Write-Host ("-" * 74)
    Write-Host ("[{0}/{1}]  {2}" -f $idx, $items.Count, $src)
    Write-Host ("-" * 74)

    # ---------------- 回滚模式 ----------------
    if ($Mode -eq 'Undo') {
        $mani = [string]$it.ManifestPath
        if (-not $mani -or -not (Test-Path -LiteralPath $mani)) {
            Write-Host "  [跳过] 没有可用的 manifest"
            $skipped++
            [void]$results.Add([pscustomobject]@{ Source=$src; Success=$false; Phase='Skipped'; Method=''; Message='缺少 manifest'; ManifestPath=$mani })
            continue
        }
        Write-Prog $idx $items.Count $src '回滚' ([int](100 * ($idx - 1) / $items.Count)) $done $failed
        $u = Undo-DirectoryMigration -ManifestPath $mani
        if ($u.Success) {
            Write-Host ("  [成功] {0}" -f $u.MethodName)
            Write-Host ("         {0}   耗时 {1} ms   移动 {2:N0} 字节" -f $u.Reason, $u.ElapsedMs, $u.MovedBytes)
            $done++
        } else {
            Write-Host ("  [失败] {0}" -f $u.ErrorMessage)
            $failed++
        }
        [void]$results.Add([pscustomobject]@{
            Source=$src; Success=[bool]$u.Success; Phase='RolledBack'
            Method=[string]$u.Method; Message=[string]$u.Reason + [string]$u.ErrorMessage
            ManifestPath=$mani; ElapsedMs=$u.ElapsedMs; MovedBytes=$u.MovedBytes
        })
        continue
    }

    # ---------------- 预检 ----------------
    Write-Prog $idx $items.Count $src '预检' ([int](100 * ($idx - 1) / $items.Count)) $done $failed
    $pre = Test-MigrationPrerequisite -Source $src -DestinationRoot $root
    foreach ($c in @($pre.Checks)) {
        Write-Host ("  [{0,-4}] {1} — {2}" -f $c.Level, $c.Name, $c.Message)
    }

    if (-not $pre.Pass) {
        Write-Host "  => 预检未通过，跳过本项（未做任何写操作）"
        $skipped++
        [void]$results.Add([pscustomobject]@{
            Source=$src; Success=$false; Phase='PreflightFailed'
            Method=''; Message='预检未通过'; ManifestPath=''
        })
        continue
    }

    if ($Mode -eq 'Preflight') {
        Write-Host "  => 预检通过（仅预检模式，未执行）"
        [void]$results.Add([pscustomobject]@{
            Source=$src; Success=$false; Phase='PreflightOnly'
            Method=''; Message='仅预检'; ManifestPath=''
        })
        continue
    }

    # ---------------- 迁移 ----------------
    Write-Host ""
    Write-Host ("  开始迁移 -> {0}" -f $pre.Plan.TargetPath)
    Write-Prog $idx $items.Count $src '复制' ([int](100 * ($idx - 1) / $items.Count)) $done $failed

    $cb = {
        param($p)
        $pct = if ($p.Total -gt 0) { [int](100 * $idx / $items.Count * 0.9 + 10 * $p.Current / $p.Total / $items.Count) } else { 0 }
        Write-Prog $idx $items.Count $src $p.Step $pct $done $failed
    }

    $r = Start-DirectoryMigration -Source $src -DestinationRoot $root -ManifestDir $ManifestDir -ProgressCallback $cb

    if ($r.Success) {
        Write-Host ("  [成功] {0:N1} 秒   复制 {1} 个文件 / {2:N1} MB" -f $r.DurationSeconds, $r.CopiedFiles, ($r.CopiedBytes/1MB))
        Write-Host ("         原位置已是 Junction: {0}" -f $src)
        Write-Host ("         manifest: {0}" -f $r.ManifestPath)
        if ($r.ErrorMessage) { Write-Host ("         注意: {0}" -f $r.ErrorMessage) }
        $done++
    } else {
        Write-Host "  [失败] 源目录未被破坏，可安全重试或跳过"
        foreach ($ln in ([string]$r.ErrorMessage -split "`n")) { Write-Host ("         " + $ln) }
        if ($r.ManifestPath) { Write-Host ("         manifest: {0}" -f $r.ManifestPath) }
        # 关键提示：失败后目标位置可能已留下一份完整副本，必须让用户知道，
        # 否则会在目标盘白占一份等量空间而无人察觉。
        if ($r.RollbackHint) {
            Write-Host ""
            foreach ($ln in ([string]$r.RollbackHint -split "`n")) { Write-Host ("         " + $ln) }
            Write-Host ""
        }
        $failed++
    }
    [void]$results.Add([pscustomobject]@{
        Source=$src; Success=[bool]$r.Success
        Phase=$(if ($r.Success) { 'Completed' } else { 'Failed' })
        Method=''; Message=[string]$r.ErrorMessage
        ManifestPath=[string]$r.ManifestPath
        TargetPath=[string]$r.TargetPath
        ElapsedMs=[int]($r.DurationSeconds * 1000)
        MovedBytes=[int64]$r.CopiedBytes
    })
}

$results = @($results)
Write-Prog $items.Count $items.Count '(完成)' '完成' 100 $done $failed

$out = [pscustomobject]@{
    Mode = $Mode
    FinishedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Total = $items.Count
    Done = $done
    Failed = $failed
    Skipped = $skipped
    Results = $results
}
$out | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ResultPath -Encoding UTF8

Write-Host ""
Write-Host ("=" * 74)
Write-Host (" 队列结束：成功 {0} / 失败 {1} / 跳过 {2} / 共 {3}" -f $done, $failed, $skipped, $items.Count)
Write-Host ("=" * 74)
Write-Host ""
