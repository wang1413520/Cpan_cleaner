#Requires -Version 5.1
<#
.SYNOPSIS
    MigrateCore 验收测试 —— 13 条，全部在临时测试目录上跑，不碰任何真实数据

.DESCRIPTION
    每条用例都用「注入」手段强制触发失败路径：
      · 在 ProgressCallback 里杀 robocopy  -> 模拟复制中断
      · 在 ProgressCallback 里删目标文件    -> 模拟校验不一致
      · 在 ProgressCallback 里占住源路径    -> 模拟 mklink 失败
      · 在 ProgressCallback 里占住残留文件  -> 模拟清理失败
    这样失败路径是被真实验证过的，而不是"看起来应该没问题"。

.USAGE
    powershell -ExecutionPolicy Bypass -File .\Run-Acceptance.ps1
#>
[CmdletBinding()]
param(
    [string]$SrcVol = 'D:',
    [string]$DstVol = 'E:'
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$ModulePath = Join-Path $PSScriptRoot 'MigrateCore.psm1'
if (-not (Test-Path -LiteralPath $ModulePath)) { throw "找不到 MigrateCore.psm1：$ModulePath" }
Import-Module $ModulePath -Force

$SRC_BASE = Join-Path $SrcVol '__mc_src'
$DST_BASE = Join-Path $DstVol '__mc_dst'
$MANI_BASE = Join-Path $env:TEMP ('mc-manifest-' + [guid]::NewGuid().ToString('N').Substring(0,6))

New-Item -ItemType Directory -Path $SRC_BASE, $DST_BASE, $MANI_BASE -Force | Out-Null

$script:Tests = New-Object System.Collections.ArrayList
# 注入标志用共享哈希表 —— 哈希表是引用类型，回调里 mutate 一定生效
$flags = @{}
function Assert {
    param([string]$Id, [string]$Name, [bool]$Ok, [string]$Detail = '')
    [void]$script:Tests.Add([pscustomobject]@{ Id=$Id; Name=$Name; Ok=$Ok; Detail=$Detail })
    $mark = if ($Ok) { '[PASS]' } else { '[FAIL]' }
    $color = if ($Ok) { 'Green' } else { 'Red' }
    Write-Host ("  {0} {1,-46} {2}" -f $mark, $Name, $Detail) -ForegroundColor $color
}

function Remove-Safe {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $it = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($it -and ($it.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        $null = cmd.exe /c "rmdir `"$Path`"" 2>&1      # 只删链接本身，绝不跟进
        return
    }
    try { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}

function New-TestTree {
    param([string]$Path, [int]$Files = 30, [int]$SizeKB = 32)
    Remove-Safe $Path
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    $nested = Join-Path $Path 'sub\nested'
    New-Item -ItemType Directory -Path $nested -Force | Out-Null
    for ($i = 1; $i -le $Files; $i++) {
        $dir = if ($i % 2 -eq 0) { $nested } else { $Path }
        $bytes = New-Object byte[] ($SizeKB * 1024)
        (New-Object System.Random $i).NextBytes($bytes)
        [System.IO.File]::WriteAllBytes((Join-Path $dir ("f{0}.bin" -f $i)), $bytes)
    }
    # 一个可以"启动"的小程序，用于验证路径透明
    Set-Content -LiteralPath (Join-Path $Path 'run.cmd') -Value "@echo off`r`necho MIGRATE_OK" -Encoding ASCII
}

function Get-FileCountFast {
    param([string]$Path)
    return (Get-DirStatProbe $Path)
}
function Get-DirStatProbe {
    param([string]$Path)
    $n = 0
    Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue | ForEach-Object { $n++ }
    return $n
}

function Test-IsLink {
    param([string]$Path)
    $it = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $it) { return $false }
    return [bool]($it.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
}

Write-Host ""
Write-Host ("=" * 96)
Write-Host (" MigrateCore 验收测试   {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Write-Host (" 源盘 $SrcVol   目标盘 $DstVol   全部使用临时目录，不碰真实数据")
Write-Host ("=" * 96)

# ============================================================
# T1  非管理员 + Junction 能力探测
# ============================================================
Write-Host "`n--- T1  Junction 能力探测（非管理员应仍可迁移）---"
$t1src = Join-Path $SRC_BASE 'T1'
New-TestTree -Path $t1src -Files 10 -SizeKB 8
$pre1 = Test-MigrationPrerequisite -Source $t1src -DestinationRoot $DST_BASE
$chkAdmin = $pre1.Checks | Where-Object { $_.Name -eq '管理员身份' }
$chkCap   = $pre1.Checks | Where-Object { $_.Name -eq 'Junction 能力' }
Assert 'T1a' 'Junction 能力探测通过' ($chkCap.Level -eq 'OK') $chkCap.Message
Assert 'T1b' '非管理员不再导致预检失败' ($chkAdmin.Level -ne 'FAIL') "管理员身份检查 = $($chkAdmin.Level)"
Assert 'T1c' '整体预检 Pass' ($pre1.Pass -eq $true) "FAIL=$($pre1.FailCount) WARN=$($pre1.WarnCount)"

# ============================================================
# T2  目标已存在 -> 预检 FAIL
# ============================================================
Write-Host "`n--- T2  目标已存在 ---"
$t2src = Join-Path $SRC_BASE 'T2'
New-TestTree -Path $t2src -Files 10 -SizeKB 8
$t2dst = Join-Path $DST_BASE 'T2'
New-Item -ItemType Directory -Path $t2dst -Force | Out-Null
$pre2 = Test-MigrationPrerequisite -Source $t2src -DestinationRoot $DST_BASE
$c2 = $pre2.Checks | Where-Object { $_.Level -eq 'FAIL' -and $_.Message -match '目标已存在' }
Assert 'T2' '目标已存在时预检 FAIL' (($pre2.Pass -eq $false) -and $c2) "Pass=$($pre2.Pass)"
Remove-Safe $t2dst

# ============================================================
# T3  源本身是 Junction -> 预检 FAIL
# ============================================================
Write-Host "`n--- T3  源本身是链接 ---"
$t3real = Join-Path $SRC_BASE 'T3_real'
$t3link = Join-Path $SRC_BASE 'T3_link'
New-TestTree -Path $t3real -Files 8 -SizeKB 8
$null = cmd.exe /c "mklink /J `"$t3link`" `"$t3real`"" 2>&1
$pre3 = Test-MigrationPrerequisite -Source $t3link -DestinationRoot $DST_BASE
$c3 = $pre3.Checks | Where-Object { $_.Level -eq 'FAIL' -and $_.Message -match '已经是链接' }
Assert 'T3' '源是已有链接时预检 FAIL' (($pre3.Pass -eq $false) -and $c3) "Pass=$($pre3.Pass)"

# ============================================================
# T4  文件被占用 -> 预检 FAIL 并列出文件名
# ============================================================
Write-Host "`n--- T4  文件被占用 ---"
$t4src = Join-Path $SRC_BASE 'T4'
New-TestTree -Path $t4src -Files 10 -SizeKB 8
$lockFile = Join-Path $t4src 'f1.bin'
$lockStream = [System.IO.File]::Open($lockFile, 'Open', 'Read', 'None')
try {
    $pre4 = Test-MigrationPrerequisite -Source $t4src -DestinationRoot $DST_BASE
    $c4 = $pre4.Checks | Where-Object { $_.Name -eq '文件占用' }
    Assert 'T4' '文件被占用时预检 FAIL 并列出文件名' (($pre4.Pass -eq $false) -and ($c4.Message -match 'f1\.bin')) "Level=$($c4.Level)"
} finally { $lockStream.Dispose() }

# ============================================================
# T5  复制中途被中断 -> 源目录完好
# ============================================================
Write-Host "`n--- T5  复制中途中断（杀 robocopy）---"
$t5src = Join-Path $SRC_BASE 'T5'
New-TestTree -Path $t5src -Files 120 -SizeKB 512    # 约 60MB，复制需要几秒
$before5 = Get-DirStatProbe $t5src
# flag -> $flags['k5']
$cb5 = {
    param($p)
    if ($p.Step -eq '复制' -and $p.Current -ge 2 -and -not $flags['k5']) {
        $flags['k5'] = $true
        Get-Process robocopy -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
}
# 用后台任务独立杀 robocopy —— 回调每 400ms 才轮询一次，小目录在 NVMe 上早就拷完了
$killer5 = Start-Job -ScriptBlock {
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        $proc = @(Get-Process robocopy -ErrorAction SilentlyContinue)
        if ($proc.Count -gt 0) {
            $proc | Stop-Process -Force -ErrorAction SilentlyContinue
            return 'killed'
        }
        Start-Sleep -Milliseconds 10
    }
    return 'timeout'
}
$r5 = Start-DirectoryMigration -Source $t5src -DestinationRoot $DST_BASE -ManifestDir $MANI_BASE
$killerResult = Receive-Job $killer5 -Wait
Remove-Job $killer5 -Force -ErrorAction SilentlyContinue
Write-Host ("    注入结果: {0}" -f $killerResult)
$after5 = Get-DirStatProbe $t5src
Assert 'T5a' '复制中断后未报成功' ($r5.Success -eq $false) ("Success=" + $r5.Success)
Assert 'T5b' '源目录完好且未被改成链接' (($after5 -eq $before5) -and (-not (Test-IsLink $t5src))) "中断前 $before5 -> 中断后 $after5"
Assert 'T5c' '错误信息指明复制失败' ($r5.ErrorMessage -match 'robocopy|校验') ($r5.ErrorMessage -replace "`n", ' ')

# ============================================================
# T6  校验不一致 -> 拒绝删除源
# ============================================================
Write-Host "`n--- T6  校验不一致（注入：校验前删掉目标里的文件）---"
$t6src = Join-Path $SRC_BASE 'T6'
New-TestTree -Path $t6src -Files 40 -SizeKB 16
$before6 = Get-DirStatProbe $t6src
$t6dst = Join-Path $DST_BASE 'T6'
# flag -> $flags['i6']
$cb6 = {
    param($p)
    if ($p.Step -eq '校验' -and -not $flags['i6']) {
        $flags['i6'] = $true
        $f = Get-ChildItem -LiteralPath $t6dst -Recurse -Force -File -EA SilentlyContinue | Select-Object -First 1
        if ($f) { Remove-Item -LiteralPath $f.FullName -Force -EA SilentlyContinue }
    }
}
$r6 = Start-DirectoryMigration -Source $t6src -DestinationRoot $DST_BASE -ManifestDir $MANI_BASE -ProgressCallback $cb6
$after6 = Get-DirStatProbe $t6src
Assert 'T6a' '校验不一致时迁移失败' ($r6.Success -eq $false) ''
Assert 'T6b' '错误信息指向校验' ($r6.ErrorMessage -match '校验不通过') ''
Assert 'T6c' '拒绝删除源（源完好）' ($after6 -eq $before6) "期望 $before6，实际 $after6"
Assert 'T6d' '源仍是普通目录' (-not (Test-IsLink $t6src)) ''

# ============================================================
# T7  成功迁移 + Junction 可见 + 程序路径透明
# ============================================================
Write-Host "`n--- T7  正常迁移全流程 ---"
$t7src = Join-Path $SRC_BASE 'T7'
New-TestTree -Path $t7src -Files 40 -SizeKB 16
$before7 = Get-DirStatProbe $t7src
$sw7 = [System.Diagnostics.Stopwatch]::StartNew()
$r7 = Start-DirectoryMigration -Source $t7src -DestinationRoot $DST_BASE -ManifestDir $MANI_BASE
$sw7.Stop()
$t7dst = Join-Path $DST_BASE 'T7'
Assert 'T7a' '迁移成功' ($r7.Success -eq $true) ("耗时 {0:N1}s" -f $sw7.Elapsed.TotalSeconds)
Assert 'T7b' '目标目录已生成' (Test-Path -LiteralPath $t7dst) $t7dst
Assert 'T7c' '原位置变成 Junction' (Test-IsLink $t7src) ("LinkType=" + (Get-Item -LiteralPath $t7src -Force).LinkType)
$dirAL = (cmd.exe /c "dir /AL `"$SRC_BASE`"" 2>&1) -join "`n"
Assert 'T7d' 'dir /AL 能看到 <JUNCTION>' ($dirAL -match '<JUNCTION>\s+T7\s') ''
$runOut = ''
try { $runOut = (cmd.exe /c "`"$t7src\run.cmd`"" 2>&1) -join ' ' } catch { $runOut = "ERR: $($_.Exception.Message)" }
Assert 'T7e' '程序可通过原路径启动（路径透明）' ($runOut -match 'MIGRATE_OK') "输出: $runOut"
$t7manifest = $r7.ManifestPath

# ============================================================
# T10 robocopy 退出码 0-7 视为成功
# ============================================================
Write-Host "`n--- T10 robocopy 退出码判定 ---"
$m7 = Get-Content -LiteralPath $t7manifest -Raw -Encoding UTF8 | ConvertFrom-Json
$stepCopy = @($m7.Steps) | Where-Object { $_.Step -eq '复制' } | Select-Object -First 1
$codeMatch = [regex]::Match([string]$stepCopy.Note, '退出码\s+(-?\d+)')
$rc7 = if ($codeMatch.Success) { [int]$codeMatch.Groups[1].Value } else { -999 }
Assert 'T10' '退出码 0-7 被判为成功（未误报失败）' (($rc7 -ge 0) -and ($rc7 -le 7) -and ($m7.Phase -eq 'Completed')) "实际退出码 $rc7，Phase=$($m7.Phase)"

# ============================================================
# T8  Undo 方案 C（从已迁移状态完整搬回）
# ============================================================
Write-Host "`n--- T8  Undo 方案 C（完整搬回）---"
$sw8 = [System.Diagnostics.Stopwatch]::StartNew()
$u8 = Undo-DirectoryMigration -ManifestPath $t7manifest
$sw8.Stop()
$after8 = Get-DirStatProbe $t7src
Assert 'T8a' 'Undo 成功' ($u8.Success -eq $true) ($u8.ErrorMessage)
Assert 'T8b' '选中最完整的方案 C' ($u8.Method -eq 'C') "Method=$($u8.Method) $($u8.MethodName)"
Assert 'T8c' '源恢复为普通目录' (-not (Test-IsLink $t7src)) ("LinkType=" + (Get-Item -LiteralPath $t7src -Force).LinkType)
Assert 'T8d' '内容完整' ($after8 -eq $before7) "期望 $before7，实际 $after8"
Assert 'T8e' '程序仍可运行' (((cmd.exe /c "`"$t7src\run.cmd`"" 2>&1) -join ' ') -match 'MIGRATE_OK') ''

# ============================================================
# T11 mklink 失败 -> 残留可重命名回滚（零数据移动）
# ============================================================
Write-Host "`n--- T11 mklink 失败（注入：占住原路径）---"
$t11src = Join-Path $SRC_BASE 'T11'
New-TestTree -Path $t11src -Files 40 -SizeKB 16
$before11 = Get-DirStatProbe $t11src
$srcParent11 = Split-Path $t11src -Parent
$srcName11 = Split-Path $t11src -Leaf
# flag -> $flags['i11']
$cb11 = {
    param($p)
    if ($p.Step -eq '切换' -and $p.Message -match 'Junction' -and -not $flags['i11']) {
        $flags['i11'] = $true
        # 源已被重命名让位，此刻在原路径放一个文件，mklink 必然失败
        Set-Content -LiteralPath $t11src -Value 'blocker' -Force -ErrorAction SilentlyContinue
    }
}
$r11 = Start-DirectoryMigration -Source $t11src -DestinationRoot $DST_BASE -ManifestDir $MANI_BASE -ProgressCallback $cb11
Assert 'T11a' 'mklink 失败导致迁移失败' ($r11.Success -eq $false) ''
Assert 'T11b' '存在 .__migrating_ 残留（源未丢失）' (@(Get-ChildItem -LiteralPath $srcParent11 -Force -Directory -EA SilentlyContinue | Where-Object { $_.Name -like "$srcName11.__migrating_*" }).Count -gt 0) ''

# 清掉注入的阻塞文件，再回滚
try { if (Test-Path -LiteralPath $t11src -PathType Leaf) { Remove-Item -LiteralPath $t11src -Force } } catch {}
$sw11 = [System.Diagnostics.Stopwatch]::StartNew()
$u11 = Undo-DirectoryMigration -ManifestPath $r11.ManifestPath
$sw11.Stop()
$after11 = Get-DirStatProbe $t11src
Assert 'T11c' 'Undo 自动选中方案 A' ($u11.Method -eq 'A') "Method=$($u11.Method) $($u11.MethodName)"
Assert 'T11d' '方案 A 是零数据移动（< 2000ms）' ($sw11.ElapsedMilliseconds -lt 2000) ("耗时 $($sw11.ElapsedMilliseconds) ms，移动字节 $($u11.MovedBytes)")
Assert 'T11e' '源已恢复且内容完整' ((-not (Test-IsLink $t11src)) -and ($after11 -eq $before11)) "期望 $before11，实际 $after11"

# ============================================================
# T12 清理残留失败 -> Success 仍为 true
# ============================================================
Write-Host "`n--- T12 清理残留失败（注入：占住残留目录内的文件）---"
$t12src = Join-Path $SRC_BASE 'T12'
New-TestTree -Path $t12src -Files 40 -SizeKB 16
$before12 = Get-DirStatProbe $t12src
$srcParent12 = Split-Path $t12src -Parent
$srcName12 = Split-Path $t12src -Leaf
$holdStream = $null
# flag -> $flags['i12']
$cb12 = {
    param($p)
    if ($p.Step -eq '清理' -and -not $flags['i12']) {
        $flags['i12'] = $true
        $bak = Get-ChildItem -LiteralPath $srcParent12 -Force -Directory -EA SilentlyContinue |
               Where-Object { $_.Name -like "$srcName12.__migrating_*" } | Select-Object -First 1
        if ($bak) {
            $f = Get-ChildItem -LiteralPath $bak.FullName -Recurse -Force -File -EA SilentlyContinue | Select-Object -First 1
            if ($f) { $flags['hs'] = [System.IO.File]::Open($f.FullName, 'Open', 'Read', 'None') }
        }
    }
}
$r12 = Start-DirectoryMigration -Source $t12src -DestinationRoot $DST_BASE -ManifestDir $MANI_BASE -ProgressCallback $cb12
Assert 'T12a' '清理失败时 Success 仍为 true' ($r12.Success -eq $true) ("ErrorMessage=" + $r12.ErrorMessage)
Assert 'T12b' '提示存在残留目录' ($r12.ErrorMessage -match '残留') ''
Assert 'T12c' 'Junction 仍可正常访问' ((Test-IsLink $t12src) -and (((cmd.exe /c "`"$t12src\run.cmd`"" 2>&1) -join ' ') -match 'MIGRATE_OK')) ''
if ($flags['hs']) { $flags['hs'].Dispose(); $flags['hs'] = $null }

# ============================================================
# T9  路径含空格与中文
# ============================================================
Write-Host "`n--- T9  路径含空格与中文 ---"
$t9src = Join-Path $SRC_BASE '测试 目录 A'
New-TestTree -Path $t9src -Files 30 -SizeKB 16
$before9 = Get-DirStatProbe $t9src
$r9 = Start-DirectoryMigration -Source $t9src -DestinationRoot $DST_BASE -ManifestDir $MANI_BASE
$t9dst = Join-Path $DST_BASE '测试 目录 A'
Assert 'T9a' '中文+空格路径迁移成功' ($r9.Success -eq $true) ($r9.ErrorMessage)
Assert 'T9b' '目标路径正确' (Test-Path -LiteralPath $t9dst) $t9dst
Assert 'T9c' '程序可通过原路径运行' (((cmd.exe /c "`"$t9src\run.cmd`"" 2>&1) -join ' ') -match 'MIGRATE_OK') ''
$u9 = Undo-DirectoryMigration -ManifestPath $r9.ManifestPath
Assert 'T9d' '中文+空格路径回滚成功' (($u9.Success -eq $true) -and ((Get-DirStatProbe $t9src) -eq $before9)) "Method=$($u9.Method)"

# ============================================================
# T13 Undo 方案 B（源缺失、目标完整 -> 补链接，零数据移动）
# ============================================================
Write-Host "`n--- T13 Undo 方案 B（断链修复）---"
$t13src = Join-Path $SRC_BASE 'T13'
New-TestTree -Path $t13src -Files 30 -SizeKB 16
$r13 = Start-DirectoryMigration -Source $t13src -DestinationRoot $DST_BASE -ManifestDir $MANI_BASE
$null = cmd.exe /c "rmdir `"$t13src`"" 2>&1     # 人为把链接摘掉，制造"断链"状态
Assert 'T13a' '已构造断链状态（源不存在，目标完整）' ((-not (Test-Path -LiteralPath $t13src)) -and (Test-Path -LiteralPath (Join-Path $DST_BASE 'T13'))) ''
$sw13 = [System.Diagnostics.Stopwatch]::StartNew()
$u13 = Undo-DirectoryMigration -ManifestPath $r13.ManifestPath
$sw13.Stop()
Assert 'T13b' 'Undo 自动选中方案 B' ($u13.Method -eq 'B') "Method=$($u13.Method) $($u13.MethodName)"
Assert 'T13c' '方案 B 是零数据移动（< 2000ms）' ($sw13.ElapsedMilliseconds -lt 2000) ("耗时 $($sw13.ElapsedMilliseconds) ms，移动字节 $($u13.MovedBytes)")
Assert 'T13d' '链接已补回且可访问' ((Test-IsLink $t13src) -and (((cmd.exe /c "`"$t13src\run.cmd`"" 2>&1) -join ' ') -match 'MIGRATE_OK')) ''

# ============================================================
# T14 方案 D：源完好 + 目标留有副本（复制成功但卡在切换时回滚后的状态）
# ============================================================
Write-Host "`n--- T14 方案 D（孤儿副本检测与清理）---"
$t14src = Join-Path $SRC_BASE 'T14'
New-TestTree -Path $t14src -Files 12 -SizeKB 8
$before14 = Get-DirStatProbe $t14src
$t14dst = Join-Path $DST_BASE 'T14'

# 1) 正常迁移 -> 2) 摘掉链接、把数据搬回源位置 -> 得到「源完好 + 目标有副本」
$r14 = Start-DirectoryMigration -Source $t14src -DestinationRoot $DST_BASE -ManifestDir $MANI_BASE
$null = cmd.exe /c "rmdir `"$t14src`"" 2>&1
$rc = Join-Path $env:SystemRoot 'System32\robocopy.exe'
& $rc $t14dst $t14src /E /XJ /NJH /NJS /NP /NDL /R:0 /W:0 | Out-Null   # 把目标搬回源位置，构造方案 D
$made = (Test-Path -LiteralPath $t14src) -and (-not (Test-IsLink $t14src)) -and (Test-Path -LiteralPath $t14dst)
Assert 'T14a' '已构造方案 D 状态（源完好 + 目标有副本）' $made ''

# 3) 不带 -CleanOrphanTarget：只检测，不删除
$u14a = Undo-DirectoryMigration -ManifestPath $r14.ManifestPath
Assert 'T14b' 'Undo 自动选中方案 D' ($u14a.Method -eq 'D') "Method=$($u14a.Method)"
Assert 'T14c' '默认只报告不删除孤儿副本' ((Test-Path -LiteralPath $t14dst) -and ($u14a.OrphanBytes -gt 0)) ("孤儿 $([math]::Round($u14a.OrphanBytes/1MB,2)) MB")
Assert 'T14d' '报告的文案已正确替换占位符' ($u14a.Reason -notmatch '\{0') ''

# 4) 把目标改坏 -> 必须拒绝删除
Remove-Item -LiteralPath (Join-Path $t14dst 'f1.bin') -Force -ErrorAction SilentlyContinue
$u14b = Undo-DirectoryMigration -ManifestPath $r14.ManifestPath -CleanOrphanTarget
Assert 'T14e' '目标与 manifest 不符时拒绝删除' ((-not $u14b.Success) -and (Test-Path -LiteralPath $t14dst)) $u14b.ErrorMessage

# 5) 修好目标 -> 清理成功且源完好
& $rc $t14src $t14dst /E /XJ /NJH /NJS /NP /NDL /R:0 /W:0 | Out-Null
$u14c = Undo-DirectoryMigration -ManifestPath $r14.ManifestPath -CleanOrphanTarget
Assert 'T14f' '修好后清理成功' ($u14c.Success -eq $true) $u14c.MethodName
Assert 'T14g' '孤儿副本已删除' (-not (Test-Path -LiteralPath $t14dst)) ''
Assert 'T14h' '源目录完好未受影响' ((Get-DirStatProbe $t14src) -eq $before14) "期望 $before14"

# ============================================================
# T15 清理功能：安全拦截 / 试运行 / 真实删除 / 链接安全
# ============================================================
Write-Host "`n--- T15 清理功能（Clean-CDriveItems.ps1）---"
$CleanScript = Join-Path $PSScriptRoot 'Clean-CDriveItems.ps1'
$t15base = Join-Path $SRC_BASE 'T15'
$t15log  = Join-Path $t15base 'logs'
Remove-Safe $t15base
New-Item -ItemType Directory -Path $t15base, $t15log -Force | Out-Null

# 造素材：普通垃圾目录 / 一个真链接 + 它的目标
$junk  = Join-Path $t15base '垃圾目录'
$linkT = Join-Path $t15base '真目标'
$link  = Join-Path $t15base '链接项'
New-Item -ItemType Directory -Path $junk, $linkT -Force | Out-Null
1..12 | ForEach-Object { [System.IO.File]::WriteAllBytes((Join-Path $junk "f$_.bin"), (New-Object byte[] 4096)) }
Set-Content -LiteralPath (Join-Path $linkT 'keep.txt') -Value 'IMPORTANT' -Encoding ASCII
$null = cmd.exe /c "mklink /J `"$link`" `"$linkT`"" 2>&1

$junkCount = @(Get-ChildItem -LiteralPath $junk -Recurse -Force -File).Count
$q = Join-Path $t15base 'q.json'; $r = Join-Path $t15base 'r.json'

function Invoke-Clean {
    param($Items, [string]$Mode, [switch]$DryRun)
    ([pscustomobject]@{ Items = @($Items) }) | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $q -Encoding UTF8
    $args = @('-QueuePath', $q, '-ResultPath', $r, '-LogDir', $t15log, '-Mode', $Mode)
    if ($DryRun) { $args += '-DryRun' }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $CleanScript @args 2>&1 | Out-Null
    return (Get-Content -LiteralPath $r -Raw -Encoding UTF8 | ConvertFrom-Json)
}

# --- 硬禁区：全部应被拦截 ---
$blocked = @(
    'C:\Windows', 'C:\Program Files', 'C:\Program Files (x86)', 'C:\ProgramData',
    'C:\Users', ('C:\Users\' + $env:USERNAME), 'C:\$Recycle.Bin', 'C:\', 'C:\System Volume Information'
)
$resBlock = Invoke-Clean -Items ($blocked | ForEach-Object { [pscustomobject]@{ Path = $_ } }) -Mode Permanent
$allBlocked = (@($resBlock.Results | Where-Object { $_.Phase -eq 'Blocked' }).Count -eq $blocked.Count) -and ($resBlock.Done -eq 0)
Assert 'T15a' '9 个硬禁区路径全部被拦截' $allBlocked "Blocked=$(@($resBlock.Results | Where-Object { $_.Phase -eq 'Blocked' }).Count)/$($blocked.Count)"
Assert 'T15b' '拦截项源目录仍存在' (Test-Path 'C:\Windows') ''

# --- 试运行：不得删除任何东西 ---
$resDry = Invoke-Clean -Items @([pscustomobject]@{ Path = $junk }) -Mode Permanent -DryRun
$dryOk = (Test-Path -LiteralPath $junk) -and (@(Get-ChildItem -LiteralPath $junk -Recurse -Force -File).Count -eq $junkCount)
Assert 'T15c' '试运行不删除任何文件' $dryOk "文件数 $junkCount"
Assert 'T15d' '试运行标记为 DryRun' (@($resDry.Results | Where-Object { $_.Phase -eq 'DryRun' }).Count -eq 1) ''

# --- 真实删除 + 链接安全 ---
$resReal = Invoke-Clean -Items @([pscustomobject]@{ Path = $junk }, [pscustomobject]@{ Path = $link }) -Mode Permanent
Assert 'T15e' '普通目录被永久删除' (-not (Test-Path -LiteralPath $junk)) ''
Assert 'T15f' '链接本身被移除' (-not (Test-Path -LiteralPath $link)) ''
Assert 'T15g' '链接目标未受影响（keep.txt 仍在）' (Test-Path -LiteralPath (Join-Path $linkT 'keep.txt')) ''
$resNE = Invoke-Clean -Items @([pscustomobject]@{ Path = (Join-Path $t15base '不存在的东西') }) -Mode Permanent
$cntNE = @($resNE.Results | Where-Object { $_.Success }).Count
Assert 'T15h' '不存在的路径被安全跳过' ($cntNE -eq 1) "Success计数=$cntNE  Total=$($resNE.Total) Phase=$(@($resNE.Results)[0].Phase)  Note=$(@($resNE.Results)[0].Note)"

# --- 防回归：用户目录下的缓存必须可清理 ---
# 曾经把 "$SD\Users" 写进了 BlockSubtree，导致 C:\Users\<用户>\AppData\... 下的
# 所有缓存（pip / npm-cache / .cache / *-updater）全被封死，清理功能形同废掉。
$uDir = Join-Path $env:TEMP ('__clean_probe_' + [guid]::NewGuid().ToString('N').Substring(0,6))
New-Item -ItemType Directory -Path $uDir -Force | Out-Null
Set-Content -LiteralPath (Join-Path $uDir 'a.txt') -Value 'x' -Encoding ASCII
$resU = Invoke-Clean -Items @([pscustomobject]@{ Path = $uDir }) -Mode Permanent
Assert 'T15i' '用户目录下的缓存可以清理（防 Users 子树误封）' ((-not (Test-Path -LiteralPath $uDir)) -and (@($resU.Results | Where-Object { $_.Success }).Count -eq 1)) ''

# --- 防回归：用户主目录本身仍必须被拦 ---
$resHome = Invoke-Clean -Items @([pscustomobject]@{ Path = $env:USERPROFILE }) -Mode Permanent -DryRun
Assert 'T15j' '用户主目录本身仍被拦截' ((@($resHome.Results | Where-Object { $_.Phase -eq 'Blocked' }).Count -eq 1) -and (Test-Path -LiteralPath $env:USERPROFILE)) ''

# 清理 T15 现场
Remove-Safe $t15base

# ============================================================
# 汇总
# ============================================================
$script:Tests = @($script:Tests)
$pass = @($script:Tests | Where-Object { $_.Ok })
$fail = @($script:Tests | Where-Object { -not $_.Ok })

Write-Host ""
Write-Host ("=" * 96)
Write-Host (" 验收结果： {0} / {1} 通过" -f $pass.Count, $script:Tests.Count) -ForegroundColor $(if ($fail.Count -eq 0) { 'Green' } else { 'Red' })
Write-Host ("=" * 96)
if ($fail.Count -gt 0) {
    Write-Host "`n未通过项：" -ForegroundColor Red
    $fail | ForEach-Object { Write-Host ("  {0}  {1}   {2}" -f $_.Id, $_.Name, $_.Detail) -ForegroundColor Red }
}

# ---- 清理测试痕迹 ----
Write-Host "`n清理测试目录…"
foreach ($d in @(Get-ChildItem -LiteralPath $SRC_BASE -Force -ErrorAction SilentlyContinue)) { Remove-Safe $d.FullName }
foreach ($d in @(Get-ChildItem -LiteralPath $DST_BASE -Force -ErrorAction SilentlyContinue)) { Remove-Safe $d.FullName }
Remove-Safe $SRC_BASE
Remove-Safe $DST_BASE
Remove-Item -LiteralPath $MANI_BASE -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "完成。"
