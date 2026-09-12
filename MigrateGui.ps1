#Requires -Version 5.1
<#
.SYNOPSIS
    C 盘迁移助手 — 图形界面（扫描 / AI 标注 / 决策清单）

.DESCRIPTION
    极简 WinForms 界面，包住两个已验证的命令行工具：
      · Scan-CDrive.ps1          规则扫描与三级标注
      · Annotate-CDriveReport.ps1 AI 标注（可选）

    三个阶段各自在独立进程里跑，界面不卡死，日志实时回显。

    ⚠️ 本界面只做「扫描 / 标注 / 导出决策清单」，不执行任何删除或迁移。
       执行模块（Junction 迁移 + 回滚）是独立的下一个模块。

.NOTES
    API Key 只保存在内存中，不写入磁盘。也可预先设置环境变量 MIGRATE_AI_KEY。
#>
[CmdletBinding()]
param()

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ============================================================
#  安全网：任何未处理异常都拦成友好提示，绝不让 .NET JIT 调试框弹出来
#  （放在创建任何窗口之前才生效）
# ============================================================
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
[System.Windows.Forms.Application]::add_ThreadException({
    param($sender, $e)
    $msg  = [string]$e.Exception.Message
    $type = $e.Exception.GetType().FullName
    try {
        Add-Content -LiteralPath (Join-Path $env:TEMP 'cdrive-gui-error.log') -Encoding UTF8 -ErrorAction SilentlyContinue `
            -Value ("{0}  [{1}]  {2}`r`n{3}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $type, $msg, $e.Exception.StackTrace)
    } catch {}
    if ($env:CDRIVE_GUI_SILENT_ERRORS -eq '1') { return }   # 自动化测试用静默模式
    try {
        [void][System.Windows.Forms.MessageBox]::Show(
            ("界面发生了一个未预期的错误，本次操作已中止。`n`n$msg`n`n" +
             "数据安全提示：如果你正在执行迁移，源目录不会被破坏。`n" +
             "可到「4. 执行迁移」页点「回滚上次执行」恢复。`n`n" +
             "错误详情已写入 %TEMP%\cdrive-gui-error.log"),
            '意外错误（已拦截）', 'OK', 'Warning')
    } catch {}
})

$ErrorActionPreference = 'Stop'

# ============================================================
#  路径与全局状态
# ============================================================
$script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ScanScript = Join-Path $script:ScriptDir 'Scan-CDrive.ps1'
$script:AnnScript  = Join-Path $script:ScriptDir 'Annotate-CDriveReport.ps1'
$script:ReportDir  = Join-Path $script:ScriptDir 'report'
$script:TempDir    = Join-Path $env:TEMP 'cdrive-gui'

if (-not (Test-Path $script:ScanScript)) { throw "找不到 Scan-CDrive.ps1：$script:ScanScript" }
if (-not (Test-Path $script:ReportDir))  { New-Item -ItemType Directory -Path $script:ReportDir -Force | Out-Null }
if (Test-Path $script:TempDir) { Remove-Item $script:TempDir -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Path $script:TempDir -Force | Out-Null

$script:ScanProc = $null; $script:ScanLog = Join-Path $script:TempDir 'scan.log'; $script:ScanOff = 0L
$script:AnnProc  = $null; $script:AnnLog  = Join-Path $script:TempDir 'ann.log';  $script:AnnOff  = 0L
$script:LastScanJson = $null

# --- 执行迁移（Tab 4）---
$script:QueueItems  = @()
$script:MigProc     = $null
$script:MigDir      = Join-Path $script:ReportDir 'migration'   # 持久化：manifest 与结果必须能在重启后回滚
$script:MigLog      = Join-Path $script:MigDir 'run.log'
$script:MigProg     = Join-Path $script:MigDir 'progress.json'
$script:MigResult   = ''   # 每次执行生成带时间戳的结果文件
$script:MigQueue    = Join-Path $script:MigDir 'queue.json'
$script:MigOff      = 0L
$script:LastResult  = $null
$script:LastRefresh = $null      # 上次「刷新状态」的时间
$script:LastRefreshChanged = 0   # 上次刷新时状态发生变化的项数

# --- 清理（Tab 3）---
$script:CleanScript = Join-Path $script:ScriptDir 'Clean-CDriveItems.ps1'
$script:ClnDir      = Join-Path $script:ReportDir 'cleanup'
$script:ClnLog      = Join-Path $script:TempDir 'clean.log'
$script:ClnResult   = Join-Path $script:TempDir 'clean-result.json'
$script:ClnQueue    = Join-Path $script:TempDir 'clean-queue.json'
$script:ClnProc     = $null
$script:ClnOff      = 0L
$script:AllRows = @()

$FontUI   = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$FontMono = New-Object System.Drawing.Font('Consolas', 9)

function New-Label { param($Text,$X,$Y,$W=90,$H=20)
    $l = New-Object System.Windows.Forms.Label
    $l.Text=$Text; $l.Location=New-Object System.Drawing.Point($X,$Y); $l.Size=New-Object System.Drawing.Size($W,$H); $l.Font=$FontUI
    return $l
}
function New-Text { param($X,$Y,$W,$Text='',$Mono=$false)
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location=New-Object System.Drawing.Point($X,$Y); $t.Size=New-Object System.Drawing.Size($W,23)
    $t.Text=$Text; $t.Font=$(if($Mono){$FontMono}else{$FontUI})
    return $t
}
function New-Btn { param($Text,$X,$Y,$W=110,$H=28)
    $b = New-Object System.Windows.Forms.Button
    $b.Text=$Text; $b.Location=New-Object System.Drawing.Point($X,$Y); $b.Size=New-Object System.Drawing.Size($W,$H); $b.Font=$FontUI
    return $b
}
function New-Log { param($X,$Y,$W,$H)
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location=New-Object System.Drawing.Point($X,$Y); $t.Size=New-Object System.Drawing.Size($W,$H)
    $t.Multiline=$true; $t.ReadOnly=$true; $t.ScrollBars='Vertical'; $t.Font=$FontMono
    $t.BackColor=[System.Drawing.Color]::FromArgb(250,250,250); $t.WordWrap=$false
    return $t
}

# ============================================================
#  主窗口
# ============================================================
$form = New-Object System.Windows.Forms.Form
$form.Text = 'C 盘迁移助手  —  扫描 / AI 标注 / 决策清单'
$form.Size = New-Object System.Drawing.Size(980, 700)
$form.StartPosition = 'CenterScreen'
$form.Font = $FontUI
$form.MinimumSize = New-Object System.Drawing.Size(820, 560)

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = 'Fill'
$tabs.Font = $FontUI
$form.Controls.Add($tabs)

# ------------------------------------------------------------
#  Tab 1  扫描
# ------------------------------------------------------------
$tabScan = New-Object System.Windows.Forms.TabPage
$tabScan.Text = '  1. 扫描  '
$tabScan.BackColor = [System.Drawing.Color]::White
[void]$tabs.TabPages.Add($tabScan)

$tabScan.Controls.Add((New-Label '扫描盘符' 16 20 70))
$txtDrive = New-Text 90 17 80 "$env:SystemDrive\"
$tabScan.Controls.Add($txtDrive)

$tabScan.Controls.Add((New-Label '最小体积 (MB)' 190 20 100))
$numMin = New-Object System.Windows.Forms.NumericUpDown
$numMin.Location=New-Object System.Drawing.Point(295,17); $numMin.Size=New-Object System.Drawing.Size(80,23)
$numMin.Minimum=1; $numMin.Maximum=100000; $numMin.Value=100; $numMin.Font=$FontUI
$tabScan.Controls.Add($numMin)

$tabScan.Controls.Add((New-Label '报告目录' 400 20 70))
$txtOut = New-Text 470 17 330 $script:ReportDir
$tabScan.Controls.Add($txtOut)
$btnOut = New-Btn '…' 806 16 30
$tabScan.Controls.Add($btnOut)

$btnScan = New-Btn '开始扫描' 16 52 110
$tabScan.Controls.Add($btnScan)
$btnOpenReport = New-Btn '打开报告目录' 132 52 120
$tabScan.Controls.Add($btnOpenReport)

$lblScanStatus = New-Label '就绪。扫描会遍历整个盘，通常需要 1~3 分钟。' 264 58 690
$lblScanStatus.ForeColor = [System.Drawing.Color]::DimGray
$tabScan.Controls.Add($lblScanStatus)

$prgScan = New-Object System.Windows.Forms.ProgressBar
$prgScan.Location=New-Object System.Drawing.Point(16,86); $prgScan.Size=New-Object System.Drawing.Size(920,6)
$prgScan.Style = 'Marquee'; $prgScan.MarqueeAnimationSpeed = 0
$tabScan.Controls.Add($prgScan)

$logScan = New-Log 16 100 920 500
$logScan.Anchor = 'Top,Left,Right,Bottom'
$tabScan.Controls.Add($logScan)

$tipScan = New-Label '本工具只做扫描与分级，不执行任何删除或迁移操作。' 16 610 900
$tipScan.Anchor = 'Left,Bottom'
$tipScan.ForeColor = [System.Drawing.Color]::FromArgb(180,60,0)
$tabScan.Controls.Add($tipScan)

# ------------------------------------------------------------
#  Tab 2  AI 标注
# ------------------------------------------------------------
$tabAnn = New-Object System.Windows.Forms.TabPage
$tabAnn.Text = '  2. AI 标注  '
$tabAnn.BackColor = [System.Drawing.Color]::White
[void]$tabs.TabPages.Add($tabAnn)

$tabAnn.Controls.Add((New-Label 'API 端点' 16 20 70))
$txtBase = New-Text 90 17 500 $env:MIGRATE_AI_BASE
$tabAnn.Controls.Add($txtBase)

$tabAnn.Controls.Add((New-Label '模型' 606 20 40))
$txtModel = New-Text 650 17 286 $env:MIGRATE_AI_MODEL
$tabAnn.Controls.Add($txtModel)

$tabAnn.Controls.Add((New-Label 'API Key' 16 52 70))
$txtKey = New-Text 90 49 500 $env:MIGRATE_AI_KEY
$txtKey.UseSystemPasswordChar = $true
$tabAnn.Controls.Add($txtKey)

$btnShowKey = New-Btn '显示' 598 48 50 24
$tabAnn.Controls.Add($btnShowKey)
$lblKeyHint = New-Label '勾选下方「记住设置」可加密保存，下次自动填入' 656 54 290
$lblKeyHint.ForeColor = [System.Drawing.Color]::DimGray
$tabAnn.Controls.Add($lblKeyHint)

$tabAnn.Controls.Add((New-Label '批量' 16 86 40))
$numBatch = New-Object System.Windows.Forms.NumericUpDown
$numBatch.Location=New-Object System.Drawing.Point(60,83); $numBatch.Size=New-Object System.Drawing.Size(60,23)
$numBatch.Minimum=1; $numBatch.Maximum=50; $numBatch.Value=15; $numBatch.Font=$FontUI
$tabAnn.Controls.Add($numBatch)

$tabAnn.Controls.Add((New-Label '最多标注条数 (0=全部)' 140 86 150))
$numLimit = New-Object System.Windows.Forms.NumericUpDown
$numLimit.Location=New-Object System.Drawing.Point(295,83); $numLimit.Size=New-Object System.Drawing.Size(70,23)
$numLimit.Minimum=0; $numLimit.Maximum=10000; $numLimit.Value=0; $numLimit.Font=$FontUI
$tabAnn.Controls.Add($numLimit)

$chkOffline = New-Object System.Windows.Forms.CheckBox
$chkOffline.Text='离线模式（不调用 API）'; $chkOffline.Location=New-Object System.Drawing.Point(390,84)
$chkOffline.Size=New-Object System.Drawing.Size(200,22); $chkOffline.Font=$FontUI
$tabAnn.Controls.Add($chkOffline)

$btnClearKey = New-Btn '清除已保存的密钥' 600 82 132 24
$tabAnn.Controls.Add($btnClearKey)

$btnTestConn = New-Btn '测试连接' 740 82 96 24
$tabAnn.Controls.Add($btnTestConn)
$tabAnn.Controls.Add($btnClearKey)

$btnDry = New-Btn '预览(不花钱)' 16 118 120
$tabAnn.Controls.Add($btnDry)
$btnAnn = New-Btn '开始标注' 142 118 110
$tabAnn.Controls.Add($btnAnn)

$chkRemember = New-Object System.Windows.Forms.CheckBox
$chkRemember.Text = '记住设置（密钥用 Windows 凭据加密保存）'
$chkRemember.Location = New-Object System.Drawing.Point(266,121)
$chkRemember.Size = New-Object System.Drawing.Size(300,22)
$chkRemember.Font = $FontUI
$chkRemember.Checked = $true
$tabAnn.Controls.Add($chkRemember)

$lblAnnStatus = New-Label '先扫描，再标注。标注结果会把「看不懂的目录」翻译成人话。' 578 124 358
$lblAnnStatus.ForeColor = [System.Drawing.Color]::DimGray
$tabAnn.Controls.Add($lblAnnStatus)

$prgAnn = New-Object System.Windows.Forms.ProgressBar
$prgAnn.Location=New-Object System.Drawing.Point(16,152); $prgAnn.Size=New-Object System.Drawing.Size(920,6)
$prgAnn.Style='Marquee'; $prgAnn.MarqueeAnimationSpeed=0
$tabAnn.Controls.Add($prgAnn)

$logAnn = New-Log 16 166 920 434
$logAnn.Anchor = 'Top,Left,Right,Bottom'
$tabAnn.Controls.Add($logAnn)

$lblAnnRule = New-Label '权限边界：AI 只有否决权，没有批准权。规则判 BLOCK 的目录绝不发给 AI。' 16 610 900
$lblAnnRule.Anchor = 'Left,Bottom'
$lblAnnRule.ForeColor = [System.Drawing.Color]::FromArgb(0,90,160)
$tabAnn.Controls.Add($lblAnnRule)

# ------------------------------------------------------------
#  Tab 3  决策清单
# ------------------------------------------------------------
$tabList = New-Object System.Windows.Forms.TabPage
$tabList.Text = '  3. 决策清单  '
$tabList.BackColor = [System.Drawing.Color]::White
[void]$tabs.TabPages.Add($tabList)

$tabList.Controls.Add((New-Label '筛选' 16 18 40))
$cmbFilter = New-Object System.Windows.Forms.ComboBox
$cmbFilter.Location=New-Object System.Drawing.Point(58,15); $cmbFilter.Size=New-Object System.Drawing.Size(126,23)
$cmbFilter.DropDownStyle='DropDownList'; $cmbFilter.Font=$FontUI
[void]$cmbFilter.Items.AddRange(@('全部','可删 DELETE','可迁 MIGRATE','重定向 REDIRECT','待定 REVIEW','已迁 ALREADY','已不存在 MISSING','禁区 BLOCK'))
$cmbFilter.SelectedIndex = 0
$tabList.Controls.Add($cmbFilter)

$btnSelDelete = New-Btn '全选可删' 194 13 78 26
$tabList.Controls.Add($btnSelDelete)
$btnSelMigrate = New-Btn '全选可迁' 276 13 78 26
$tabList.Controls.Add($btnSelMigrate)
$btnSelNone = New-Btn '全不选' 358 13 62 26
$tabList.Controls.Add($btnSelNone)
$btnExport = New-Btn '导出清单' 424 13 80 26
$tabList.Controls.Add($btnExport)

$btnRefreshState = New-Btn '刷新状态' 508 13 72 26
$btnRefreshState.Font = $FontUI
$tabList.Controls.Add($btnRefreshState)

$btnClean = New-Btn '清理勾选项' 584 13 96 26
$btnClean.Font = $FontUI
$btnClean.ForeColor = [System.Drawing.Color]::FromArgb(176,0,32)
$tabList.Controls.Add($btnClean)

$lblListStat = New-Label '' 686 19 250
$lblListStat.Anchor = 'Top,Right'
$tabList.Controls.Add($lblListStat)

$lv = New-Object System.Windows.Forms.ListView
$lv.Location=New-Object System.Drawing.Point(16,48); $lv.Size=New-Object System.Drawing.Size(920,398)
$lv.View='Details'; $lv.CheckBoxes=$true; $lv.FullRowSelect=$true; $lv.GridLines=$true
$lv.Font=$FontUI; $lv.Anchor='Top,Left,Right'
[void]$lv.Columns.Add('选择',45)
[void]$lv.Columns.Add('判定',82)
[void]$lv.Columns.Add('体积GB',70)
[void]$lv.Columns.Add('绝对路径',360)
[void]$lv.Columns.Add('是什么 (AI)',180)
[void]$lv.Columns.Add('AI建议',70)
[void]$lv.Columns.Add('置信',50)
[void]$lv.Columns.Add('依据',330)
$tabList.Controls.Add($lv)

$logCln = New-Log 16 474 920 122
$logCln.Anchor = 'Top,Left,Right,Bottom'
$tabList.Controls.Add($logCln)

$lblSel = New-Label '' 16 452 900
$lblSel.Anchor='Left,Right,Bottom'
$lblSel.ForeColor=[System.Drawing.Color]::FromArgb(0,90,160)
$tabList.Controls.Add($lblSel)

$lblListTip = New-Label '「导出清单」只生成文件；「清理勾选项」只对判定为「可删 DELETE」的项生效，且会先弹确认预览。' 16 606 900
$lblListTip.Anchor='Left,Bottom'
$lblListTip.ForeColor=[System.Drawing.Color]::FromArgb(180,60,0)
$tabList.Controls.Add($lblListTip)

# ------------------------------------------------------------
#  Tab 4  执行迁移
# ------------------------------------------------------------
$tabRun = New-Object System.Windows.Forms.TabPage
$tabRun.Text = '  4. 执行迁移  '
$tabRun.BackColor = [System.Drawing.Color]::White
[void]$tabs.TabPages.Add($tabRun)

$tabRun.Controls.Add((New-Label '目标盘父目录' 16 20 90))
$txtDest = New-Text 112 17 556 ''
$tabRun.Controls.Add($txtDest)
$btnDest = New-Btn '…' 674 16 30
$tabRun.Controls.Add($btnDest)
$lblDestHint = New-Label '最终路径 = 父目录 \ 源文件夹名' 712 22 224
$lblDestHint.ForeColor = [System.Drawing.Color]::DimGray
$tabRun.Controls.Add($lblDestHint)

$btnLoad = New-Btn '① 载入勾选项' 16 52 116
$tabRun.Controls.Add($btnLoad)
$btnPre = New-Btn '② 仅预检' 138 52 88
$tabRun.Controls.Add($btnPre)
$btnRun = New-Btn '③ 开始执行' 232 52 96
$tabRun.Controls.Add($btnRun)
$btnStop = New-Btn '停止' 334 52 56
$btnStop.Enabled = $false
$tabRun.Controls.Add($btnStop)
$btnUndo = New-Btn '回滚上次执行' 396 52 104
$tabRun.Controls.Add($btnUndo)

$lblRunStatus = New-Label '先在「3. 决策清单」勾选要迁移的目录，再回到这里。' 516 58 420
$lblRunStatus.ForeColor = [System.Drawing.Color]::DimGray
$tabRun.Controls.Add($lblRunStatus)

$prgRun = New-Object System.Windows.Forms.ProgressBar
$prgRun.Location = New-Object System.Drawing.Point(16,86)
$prgRun.Size = New-Object System.Drawing.Size(920,16)
$prgRun.Minimum = 0; $prgRun.Maximum = 100; $prgRun.Value = 0
$tabRun.Controls.Add($prgRun)

$lvRun = New-Object System.Windows.Forms.ListView
$lvRun.Location = New-Object System.Drawing.Point(16,110)
$lvRun.Size = New-Object System.Drawing.Size(920,188)
$lvRun.View = 'Details'; $lvRun.FullRowSelect = $true; $lvRun.GridLines = $true; $lvRun.Font = $FontUI
$lvRun.Anchor = 'Top,Left,Right'
[void]$lvRun.Columns.Add('#', 40)
[void]$lvRun.Columns.Add('源目录', 320)
[void]$lvRun.Columns.Add('状态', 96)
[void]$lvRun.Columns.Add('说明', 450)
$tabRun.Controls.Add($lvRun)

$logRun = New-Log 16 306 920 292
$logRun.Anchor = 'Top,Left,Right,Bottom'
$tabRun.Controls.Add($logRun)

$lblRunTip = New-Label '执行会真正移动数据：每项先跑完整预检，不通过即跳过；复制与校验通过后才会建链接并删除源。失败不破坏源目录，全部可回滚。' 16 610 900
$lblRunTip.Anchor = 'Left,Bottom'
$lblRunTip.ForeColor = [System.Drawing.Color]::FromArgb(180,60,0)
$tabRun.Controls.Add($lblRunTip)

# ============================================================
#  后台任务：启动 / 轮询 / 收尾
# ============================================================
function Start-Bg {
    param([string]$ScriptPath, [string[]]$ScriptArgs, [string]$LogPath)
    if (Test-Path $LogPath) { Remove-Item $LogPath -Force -EA SilentlyContinue }

    # 用 -Command 包一层 *>&1 | Out-File -Encoding UTF8，
    # 保证 Write-Host 的中文能正确写入（否则子进程按 CP936 输出会乱码）
    # 关键：参数名（以 - 开头）绝不能加引号，否则会被当成字符串按位置绑定，
    # 例如 '-Offline' 会落到 -ReportPath 上，整个调用全乱。只有「值」才加引号。
    $parts = foreach ($a in $ScriptArgs) {
        $s = [string]$a
        if ($s.StartsWith('-')) { $s }
        else { "'" + $s.Replace("'", "''") + "'" }
    }
    $inner = "& '$ScriptPath' " + ($parts -join ' ') +
             " *>&1 | Out-File -LiteralPath '$LogPath' -Encoding UTF8"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -Command `"$inner`""
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    return [System.Diagnostics.Process]::Start($psi)
}

function Read-NewLines {
    param([string]$LogPath, [ref]$Offset)
    if (-not (Test-Path $LogPath)) { return '' }
    try {
        $fs = [System.IO.File]::Open($LogPath, 'Open', 'Read', 'ReadWrite')
        try {
            if ($fs.Length -le $Offset.Value) { return '' }
            [void]$fs.Seek($Offset.Value, 'Begin')
            $buf = New-Object byte[] ($fs.Length - $Offset.Value)
            [void]$fs.Read($buf, 0, $buf.Length)
            $Offset.Value = $fs.Length
            $s = [System.Text.Encoding]::UTF8.GetString($buf)
            return $s.TrimStart([char]0xFEFF)
        } finally { $fs.Dispose() }
    } catch { return '' }
}

function Append-Log {
    param($Box, [string]$Text)
    if (-not $Text) { return }
    $Box.AppendText($Text)
    $Box.SelectionStart = $Box.TextLength
    $Box.ScrollToCaret()
}

function Get-LatestScanJson {
    $c = @(Get-ChildItem -LiteralPath $script:ReportDir -Filter 'cdrive-scan-*.json' -EA SilentlyContinue |
           Sort-Object LastWriteTime -Descending)
    if ($c.Count -gt 0) { return $c[0].FullName }
    return $null
}
function Get-LatestAnnotatedJson {
    $c = @(Get-ChildItem -LiteralPath $script:ReportDir -Filter 'annotated-*.json' -EA SilentlyContinue |
           Sort-Object LastWriteTime -Descending)
    if ($c.Count -gt 0) { return $c[0].FullName }
    return $null
}

# ---- 列颜色 ----
$script:VColor = @{
    DELETE   = [System.Drawing.Color]::FromArgb(176,0,32)
    MIGRATE  = [System.Drawing.Color]::FromArgb(0,80,176)
    REDIRECT = [System.Drawing.Color]::FromArgb(200,110,0)
    REVIEW   = [System.Drawing.Color]::DimGray
    ALREADY  = [System.Drawing.Color]::FromArgb(0,128,64)
    MISSING  = [System.Drawing.Color]::FromArgb(140,140,140)
    BLOCK    = [System.Drawing.Color]::Gray
}

function Load-List {
    param([string]$JsonPath)

    if (-not $JsonPath -or -not (Test-Path $JsonPath)) { return }
    $parsed = Get-Content -LiteralPath $JsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $rows = @($parsed)

    # 判断是扫描报告还是标注报告
    $isAnnotated = $false
    if ($rows.Count -gt 0 -and ($rows[0].PSObject.Properties.Name -contains 'FinalVerdict')) { $isAnnotated = $true }

    $script:AllRows = foreach ($r in $rows) {
        $verdict = if ($isAnnotated) { $r.FinalVerdict } else { $r.Verdict }
        [pscustomobject]@{
            Verdict = $verdict
            SizeGB  = [double]$r.SizeGB
            Path    = [string]$r.Path
            Identity= if ($isAnnotated) { [string]$r.Identity } else { '' }
            AiSugg  = if ($isAnnotated) { Convert-AiSugg ([string]$r.AiSuggestion) } else { '' }
            AiConf  = if ($isAnnotated) { [string]$r.AiConfidence } else { '' }
            Reason  = if ($isAnnotated) { [string]$r.AiReason } else { [string]$r.Reason }
            RuleRea = if ($isAnnotated) { [string]$r.RuleReason } else { [string]$r.Reason }
            Rule    = if ($isAnnotated) { [string]$r.RuleVerdict } else { [string]$r.Verdict }
            Veto    = if ($isAnnotated) { [bool]$r.AiVeto } else { $false }
        }
    }
    Refresh-List
}

function Refresh-List {
    $lv.BeginUpdate()
    $lv.Items.Clear()
    $sel = $cmbFilter.SelectedItem
    $want = switch -Wildcard ($sel) {
        '可删*'   { 'DELETE' }
        '可迁*'   { 'MIGRATE' }
        '重定向*' { 'REDIRECT' }
        '待定*'   { 'REVIEW' }
        '已迁*'   { 'ALREADY' }
        '已不存在*' { 'MISSING' }
        '禁区*'   { 'BLOCK' }
        default   { $null }
    }

    foreach ($r in ($script:AllRows | Sort-Object SizeGB -Descending)) {
        if ($want -and $r.Verdict -ne $want) { continue }
        $sizeTxt = if ($r.Verdict -eq 'ALREADY') { [string][char]0x2014 } else { '{0:N2}' -f $r.SizeGB }
        $it = New-Object System.Windows.Forms.ListViewItem('')
        [void]$it.SubItems.Add($r.Verdict)
        [void]$it.SubItems.Add($sizeTxt)
        [void]$it.SubItems.Add($r.Path)
        [void]$it.SubItems.Add($r.Identity)
        [void]$it.SubItems.Add($r.AiSugg)
        [void]$it.SubItems.Add($r.AiConf)
        $rea = if ($r.Reason) { $r.Reason } else { $r.RuleRea }
        if ($r.Veto) { $rea = '[AI 否决] ' + $rea }
        [void]$it.SubItems.Add($rea)
        if ($r.Verdict -and $script:VColor.ContainsKey($r.Verdict)) { $it.ForeColor = $script:VColor[$r.Verdict] }
        $it.Tag = $r
        [void]$lv.Items.Add($it)
    }
    $lv.EndUpdate()
    Update-Stat
}

function Update-Stat {
    $shown = $lv.Items.Count
    # 只统计「可操作」的三类，BLOCK/ALREADY 不计入（否则数字被禁区淹没，没有意义）
    $act = @($script:AllRows | Where-Object { $_.Verdict -in @('DELETE','MIGRATE','REDIRECT') })
    $sumAct = 0.0
    if ($act.Count -gt 0) { $sumAct = [double](($act | Measure-Object SizeGB -Sum).Sum) }
    $checked = @($lv.CheckedItems)
    $sumChk = 0.0
    foreach ($ci in $checked) { if ($ci.Tag) { $sumChk += [double]$ci.Tag.SizeGB } }
    # 紧凑一行，避免在 250px 宽度里被截断
    $rf = ''
    if ($script:LastRefresh) { $rf = "  ·  {0}" -f $script:LastRefresh.ToString('HH:mm:ss') }
    $lblListStat.Text = ("{0}/{1}  ·  可操作 {2:N2} GB{3}" -f $shown, $script:AllRows.Count, $sumAct, $rf)
    $lblSel.Text = ("已勾选 {0} 项，合计 {1:N2} GB" -f $checked.Count, $sumChk)
}

# ============================================================
#  执行迁移：辅助函数
# ============================================================
$script:RunnerScript = Join-Path $script:ScriptDir 'Invoke-MigrationQueue.ps1'
if (Test-Path 'D:\') { $txtDest.Text = 'D:\moved' }

# ============================================================
#  AI 设置持久化
#  端点/模型/批量明文保存；API Key 用 Windows DPAPI 加密（当前用户作用域），
#  只有同一台机器上的同一个 Windows 账户能解开 —— 配置文件被拷走也用不了。
# ============================================================
$script:CfgPath = Join-Path $script:ScriptDir 'ai-config.json'

function Protect-Secret {
    param([string]$Plain)
    if ([string]::IsNullOrEmpty($Plain)) { return '' }
    try { return (ConvertFrom-SecureString (ConvertTo-SecureString $Plain -AsPlainText -Force)) }
    catch { return '' }
}
function Unprotect-Secret {
    param([string]$Enc)
    if ([string]::IsNullOrEmpty($Enc)) { return '' }
    try {
        $sec = ConvertTo-SecureString $Enc
        return (New-Object System.Net.NetworkCredential('', $sec)).Password
    } catch { return '' }
}

function Save-AiConfig {
    try {
        $o = [pscustomobject]@{
            ApiBase         = $txtBase.Text.Trim()
            Model           = $txtModel.Text.Trim()
            BatchSize       = [int]$numBatch.Value
            Limit           = [int]$numLimit.Value
            SaveKey         = [bool]$chkRemember.Checked
            ApiKeyProtected = if ($chkRemember.Checked) { Protect-Secret $txtKey.Text } else { '' }
            SavedAt         = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        }
        $o | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:CfgPath -Encoding UTF8
        return $true
    } catch { return $false }
}

function Load-AiConfig {
    if (-not (Test-Path -LiteralPath $script:CfgPath)) { return 'none' }
    try {
        $c = Get-Content -LiteralPath $script:CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($c.ApiBase) { $txtBase.Text = [string]$c.ApiBase }
        if ($c.Model)   { $txtModel.Text = [string]$c.Model }
        if ($null -ne $c.BatchSize) { $numBatch.Value = [decimal]$c.BatchSize }
        if ($null -ne $c.Limit)     { $numLimit.Value = [decimal]$c.Limit }
        $chkRemember.Checked = [bool]$c.SaveKey
        if ($c.ApiKeyProtected) {
            $k = Unprotect-Secret ([string]$c.ApiKeyProtected)
            if ($k) { $txtKey.Text = $k; return 'ok' }
            return 'keyfail'     # 有加密串但解不开（换了账户/机器）
        }
        return 'ok'
    } catch { return 'fail' }
}

function Test-AiConnectionInline {
    <#
    .SYNOPSIS
        发一条最小请求验证「端点 + 模型 + Key」是否可用。
        只发固定的一小段提示词，不涉及任何本机目录数据。
    #>
    $base  = $txtBase.Text.Trim().TrimEnd('/')
    $model = $txtModel.Text.Trim()
    $key   = $txtKey.Text
    if (-not $base -or -not $model -or -not $key) {
        return @{ Ok = $false; Msg = '请先填写端点、模型和 API Key。' }
    }

    $uri = $base + '/chat/completions'
    $payload = @{
        model    = $model
        messages = @(
            @{ role = 'system'; content = '你只输出 JSON，不要任何其他内容。' }
            @{ role = 'user';   content = '请输出：{"ok":true,"msg":"连接正常"}' }
        )
    }
    $json  = $payload | ConvertTo-Json -Depth 8 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $hdr   = @{ Authorization = "Bearer $key" }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $r = Invoke-WebRequest -Uri $uri -Method Post -Headers $hdr -Body $bytes `
             -ContentType 'application/json; charset=utf-8' -TimeoutSec 30 -UseBasicParsing
        $sw.Stop()
        # 与正式调用走同一条解码路径，顺带验证编码
        $raw = [System.Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
        $o = $raw | ConvertFrom-Json
        $c = [string]$o.choices[0].message.content
        if (-not $c) {
            $head = if ($raw.Length -gt 220) { $raw.Substring(0, 220) + '…' } else { $raw }
            return @{ Ok = $false; Msg = "接口通了，但返回里没有 choices[0].message.content。`n原始响应：$head" }
        }
        $snip = $c.Trim()
        if ($snip.Length -gt 90) { $snip = $snip.Substring(0, 90) + '…' }
        return @{ Ok = $true; Msg = ("连接成功`n  端点  $base`n  模型  $model`n  延迟  $($sw.ElapsedMilliseconds) ms`n  返回  $snip") }
    }
    catch {
        $sw.Stop()
        $detail = $_.Exception.Message
        try {
            $resp = $_.Exception.Response
            if ($resp) {
                $code = [int]$resp.StatusCode
                $sr = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
                $body = $sr.ReadToEnd(); $sr.Close()
                if ($body.Length -gt 300) { $body = $body.Substring(0, 300) + '…' }
                $detail = "HTTP $code`n$body"
            }
        } catch {}
        return @{ Ok = $false; Msg = ("连接失败（$($sw.ElapsedMilliseconds) ms）`n$detail") }
    }
}

# ============================================================
#  清理功能（只对「可删 DELETE」生效）
# ============================================================
function Convert-AiSugg {
    # AI 返回的是 keep/review/delete/migrate 枚举，界面上汉化一下
    param([string]$s)
    switch ($s.ToLower()) {
        'keep'    { return '别动' }
        'review'  { return '待定' }
        'delete'  { return '可删' }
        'migrate' { return '可迁' }
        default   { return $s }
    }
}

function Get-CleanableItems {
    <#
    .SYNOPSIS
        从勾选项中筛出「允许清理」的项，其余连同原因一起返回。
        第一道闸门：判定必须是 DELETE（AI 否决过的一律不算）。
        第二道闸门：硬禁区名单。
    #>
    param($Checked)
    $ok = New-Object System.Collections.ArrayList
    $rej = New-Object System.Collections.ArrayList
    foreach ($ci in $Checked) {
        $r = $ci.Tag
        if (-not $r) { continue }
        $v = [string]$r.Verdict
        if ($v -ne 'DELETE') {
            [void]$rej.Add([pscustomobject]@{ Path = [string]$r.Path; Reason = "判定为「$v」，只有「可删 DELETE」允许清理" })
            continue
        }
        $pp = [string]$r.Path
        $bad = ''
        if     ($pp -match '^[A-Za-z]:\\?$')              { $bad = '驱动器根目录' }
        elseif ($pp -match '\\\$Recycle\.Bin')            { $bad = '回收站（请用系统的「清空回收站」）' }
        elseif ($pp -match '^[A-Za-z]:\\Windows(\\|$)')   { $bad = 'Windows 目录' }
        elseif ($pp -match '^[A-Za-z]:\\Program Files')   { $bad = 'Program Files' }
        elseif ($pp -match '^[A-Za-z]:\\Users\\[^\\]+$')  { $bad = '用户主目录本身' }
        elseif ($pp -match '^[A-Za-z]:\\Users$')          { $bad = 'Users 目录' }
        if ($bad) { [void]$rej.Add([pscustomobject]@{ Path = $pp; Reason = "受保护：$bad" }); continue }
        [void]$ok.Add($r)
    }
    return @{ Ok = @($ok); Rejected = @($rej) }
}

function Show-CleanupConfirm {
    <#
    .SYNOPSIS
        清理确认对话框：完整列出将要处理的项，选择模式，勾选确认后才可执行。
    #>
    param($Items, $Rejected)

    $items = @($Items); $rej = @($Rejected)
    $total = 0.0
    foreach ($r in $items) { $total += [double]$r.SizeGB }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = '确认清理'
    $dlg.Font = $FontUI
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.StartPosition = 'CenterParent'

    $y = 12
    $lbl = New-Label ("将处理以下 {0} 项，合计 {1:N2} GB：" -f $items.Count, $total) 16 $y 660
    $dlg.Controls.Add($lbl); $y += 26

    $lvw = New-Object System.Windows.Forms.ListView
    $lvw.Location = New-Object System.Drawing.Point(16, $y)
    $lvw.Size = New-Object System.Drawing.Size(672, 250)
    $lvw.View = 'Details'; $lvw.FullRowSelect = $true; $lvw.GridLines = $true; $lvw.Font = $FontUI
    [void]$lvw.Columns.Add('体积GB', 70)
    [void]$lvw.Columns.Add('绝对路径', 590)
    foreach ($r in $items) {
        $it = New-Object System.Windows.Forms.ListViewItem(('{0:N2}' -f [double]$r.SizeGB))
        [void]$it.SubItems.Add([string]$r.Path)
        [void]$lvw.Items.Add($it)
    }
    $dlg.Controls.Add($lvw); $y += 260

    if ($rej.Count -gt 0) {
        $rl = New-Label ("以下 {0} 项不符合清理条件，已自动排除：" -f $rej.Count) 16 $y 660
        $rl.ForeColor = [System.Drawing.Color]::FromArgb(200,110,0)
        $dlg.Controls.Add($rl); $y += 22
        $txtRej = New-Object System.Windows.Forms.TextBox
        $txtRej.Location = New-Object System.Drawing.Point(16, $y)
        $txtRej.Size = New-Object System.Drawing.Size(672, 58)
        $txtRej.Multiline = $true; $txtRej.ReadOnly = $true; $txtRej.ScrollBars = 'Vertical'
        $txtRej.Font = $FontMono; $txtRej.BackColor = [System.Drawing.Color]::FromArgb(250,250,250)
        $txtRej.Text = (($rej | ForEach-Object { "$($_.Path)   ——   $($_.Reason)" }) -join "`r`n")
        $dlg.Controls.Add($txtRej); $y += 66
    }

    $rbRecycle = New-Object System.Windows.Forms.RadioButton
    $rbRecycle.Text = '移入回收站（可恢复，推荐）'
    $rbRecycle.Location = New-Object System.Drawing.Point(16, $y)
    $rbRecycle.Size = New-Object System.Drawing.Size(250, 22)
    $rbRecycle.Checked = $true; $rbRecycle.Font = $FontUI
    $dlg.Controls.Add($rbRecycle)

    $rbPerm = New-Object System.Windows.Forms.RadioButton
    $rbPerm.Text = '永久删除（不可恢复）'
    $rbPerm.Location = New-Object System.Drawing.Point(280, $y)
    $rbPerm.Size = New-Object System.Drawing.Size(250, 22); $rbPerm.Font = $FontUI
    $dlg.Controls.Add($rbPerm); $y += 32

    $chk = New-Object System.Windows.Forms.CheckBox
    $chk.Text = '我已确认以上内容无误'
    $chk.Location = New-Object System.Drawing.Point(16, $y)
    $chk.Size = New-Object System.Drawing.Size(300, 22); $chk.Font = $FontUI
    $dlg.Controls.Add($chk); $y += 34

    $btnGo = New-Btn '执行清理' 458 $y 110 28
    $btnGo.Enabled = $false
    $btnGo.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $dlg.Controls.Add($btnGo)
    $btnCancel = New-Btn '取消' 578 $y 110 28
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dlg.Controls.Add($btnCancel)

    $chk.Add_CheckedChanged({ $btnGo.Enabled = $chk.Checked })

    $dlg.ClientSize = New-Object System.Drawing.Size(704, ($y + 46))

    $res  = $dlg.ShowDialog($form)
    $mode = if ($rbPerm.Checked) { 'Permanent' } else { 'Recycle' }
    $dlg.Dispose()

    if ($res -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
    return @{ Mode = $mode; Count = $items.Count }
}

function Start-CleanJob {
    param([string]$Mode, $Items)
    if ($script:ClnProc -and -not $script:ClnProc.HasExited) { return $false }
    if (-not (Test-Path -LiteralPath $script:CleanScript)) {
        [void][System.Windows.Forms.MessageBox]::Show("找不到清理执行器：$script:CleanScript", '缺少文件'); return $false
    }
    if (-not (Test-Path -LiteralPath $script:ClnDir)) { New-Item -ItemType Directory -Path $script:ClnDir -Force | Out-Null }

    $payload = @($Items | ForEach-Object {
        [pscustomobject]@{ Path = [string]$_.Path; SizeGB = [double]$_.SizeGB }
    })
    ([pscustomobject]@{ Items = $payload }) | ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath $script:ClnQueue -Encoding UTF8
    Remove-Item -LiteralPath $script:ClnResult -Force -ErrorAction SilentlyContinue

    $script:ClnOff = 0
    $logCln.Clear()
    $script:ClnProc = Start-Bg -ScriptPath $script:CleanScript -ScriptArgs @(
        '-QueuePath',  $script:ClnQueue,
        '-ResultPath', $script:ClnResult,
        '-LogDir',     $script:ClnDir,
        '-Mode',       $Mode) -LogPath $script:ClnLog
    return $true
}

function Set-RunButtons {
    param([bool]$Enabled)
    $btnLoad.Enabled = $Enabled
    $btnPre.Enabled  = $Enabled
    $btnRun.Enabled  = $Enabled
    $btnUndo.Enabled = $Enabled
    $btnStop.Enabled = -not $Enabled
}

function Start-MigJob {
    param([string]$Mode, $Items)
    if ($script:MigProc -and -not $script:MigProc.HasExited) { return $false }
    if (-not (Test-Path -LiteralPath $script:RunnerScript)) {
        [void][System.Windows.Forms.MessageBox]::Show("找不到执行器：$script:RunnerScript", '缺少文件'); return $false
    }
    if (-not (Test-Path -LiteralPath $script:MigDir)) { New-Item -ItemType Directory -Path $script:MigDir -Force | Out-Null }
    [pscustomobject]@{ DestinationRoot = $txtDest.Text.Trim(); Items = @($Items) } |
        ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:MigQueue -Encoding UTF8
    $script:MigResult = Join-Path $script:MigDir ('result-' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '.json')
    Remove-Item -LiteralPath $script:MigProg -Force -ErrorAction SilentlyContinue
    # 只保留最近 20 份结果，避免无限堆积
    $old = @(Get-ChildItem -LiteralPath $script:MigDir -Filter 'result-*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -Skip 20)
    foreach ($f in $old) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
    $script:MigOff = 0
    $logRun.Clear()
    $prgRun.Value = 0
    $script:MigProc = Start-Bg -ScriptPath $script:RunnerScript -ScriptArgs @(
        '-QueuePath',    $script:MigQueue,
        '-ProgressPath', $script:MigProg,
        '-ResultPath',   $script:MigResult,
        '-Mode',         $Mode,
        '-ManifestDir',  $script:MigDir) -LogPath $script:MigLog
    return $true
}

function Show-RunResults {
    param($Res)
    $lvRun.BeginUpdate()
    $lvRun.Items.Clear()
    $i = 0
    foreach ($r in @($Res.Results)) {
        $i++
        $st = '失败'; $col = [System.Drawing.Color]::FromArgb(176,0,32)
        switch ([string]$r.Phase) {
            'Completed'       { $st = '成功';       $col = [System.Drawing.Color]::FromArgb(0,128,64) }
            'RolledBack'      { $st = '已回滚';     $col = [System.Drawing.Color]::FromArgb(0,128,64) }
            'PreflightOnly'   { $st = '预检通过';   $col = [System.Drawing.Color]::FromArgb(0,80,176) }
            'PreflightFailed' { $st = '预检未通过'; $col = [System.Drawing.Color]::FromArgb(200,110,0) }
            'Skipped'         { $st = '跳过';       $col = [System.Drawing.Color]::DimGray }
        }
        $msg = ''
        if ($r.TargetPath) { $msg = '-> ' + [string]$r.TargetPath }
        else { $msg = [string]$r.Message }
        if ($r.ManifestPath) { $msg += '   [manifest: ' + (Split-Path ([string]$r.ManifestPath) -Leaf) + ']' }
        $it = New-Object System.Windows.Forms.ListViewItem([string]$i)
        [void]$it.SubItems.Add([string]$r.Source)
        [void]$it.SubItems.Add($st)
        [void]$it.SubItems.Add($msg)
        $it.ForeColor = $col
        [void]$lvRun.Items.Add($it)
    }
    $lvRun.EndUpdate()
    $lblRunStatus.Text = ('结束：成功 {0} / 失败 {1} / 跳过 {2} / 共 {3}' -f $Res.Done, $Res.Failed, $Res.Skipped, $Res.Total)
}

function Get-ReparseTarget {
    <#
    .SYNOPSIS
        读链接目标。返回 '' 表示「是重解析点但不是链接」（如 OneDrive 云同步占位）。
        PS 5.1 的 .Target 读不到旧式兼容链接，回退用 dir /AL 解析。
    #>
    param([string]$Path)

    $it = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $it) { return $null }
    $tg = ''
    try { $tg = ($it.Target -join ',') } catch {}
    if ($tg) { return $tg }

    $parent = Split-Path $Path -Parent
    $name = Split-Path $Path -Leaf
    if ($parent) {
        try {
            foreach ($ln in @(cmd.exe /c "dir /AL `"$parent`"" 2>$null)) {
                $m = [regex]::Match([string]$ln, '^\s*\S+\s+\S+\s+<(\w+)>\s+(.+?)\s+\[(.+)\]\s*$')
                if ($m.Success -and $m.Groups[2].Value.Trim() -eq $name) { return $m.Groups[3].Value.Trim() }
            }
        } catch {}
    }
    return ''
}

function Update-RowState {
    <#
    .SYNOPSIS
        刷新决策清单：重新读取每个路径在磁盘上的当前状态。
        已经迁移完的目录会从 MIGRATE 变成 ALREADY，列表就不会再显示已搬走的东西。
        只对已知路径逐个 stat，不重新遍历磁盘，所以是瞬时的（143 项 < 1 秒）。
    #>
    param([switch]$Quiet)

    $rows = @($script:AllRows)
    if ($rows.Count -eq 0) { return 0 }

    $changed = 0
    foreach ($r in $rows) {
        $p = [string]$r.Path
        if (-not $p) { continue }

        $it = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
        if (-not $it) {
            if ($r.Verdict -ne 'MISSING') {
                $r.Verdict = 'MISSING'; $r.Rule = 'MISSING'; $r.SizeGB = 0
                $r.Reason = '路径已不存在'
                $changed++
            }
            continue
        }

        $isLink = [bool]($it.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
        if ($isLink -and $r.Verdict -ne 'ALREADY') {
            $tgt = Get-ReparseTarget -Path $p
            # 只有确实解析出链接目标才算「已迁移」。
            # 目标是空串说明是「非链接型重解析点」（OneDrive 等云同步占位），
            # 它既没被迁移也不该被当作已处理 —— 保持原判定不动。
            if ($tgt) {
                $r.Verdict = 'ALREADY'; $r.Rule = 'ALREADY'; $r.SizeGB = 0
                $r.Reason = "已迁移，现在是指向 $tgt 的链接"
                $changed++
            }
        }
    }

    $script:LastRefresh = Get-Date
    $script:LastRefreshChanged = $changed
    Refresh-List
    if (-not $Quiet) {
        $m = if ($changed -gt 0) { "刷新完成：$changed 项状态已更新" } else { '刷新完成：状态无变化' }
        [void][System.Windows.Forms.MessageBox]::Show(
            ($m + "`n`n已迁移的目录会归入「已迁 ALREADY」，`n切到该筛选或「全部」即可查看。"),
            '刷新状态')
    }
    return $changed
}

# ============================================================
#  事件绑定
# ============================================================
$btnOut.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.SelectedPath = $txtOut.Text
    if ($dlg.ShowDialog() -eq 'OK') { $txtOut.Text = $dlg.SelectedPath }
})
$btnOpenReport.Add_Click({
    $p = $txtOut.Text
    if (Test-Path $p) { Start-Process explorer.exe $p }
})

$btnScan.Add_Click({
    if ($script:ScanProc -and -not $script:ScanProc.HasExited) { return }
    $script:ScanOff = 0
    $logScan.Clear()
    $lblScanStatus.Text = '扫描中…（遍历整个盘，请耐心等待）'
    $lblScanStatus.ForeColor = [System.Drawing.Color]::FromArgb(200,110,0)
    $prgScan.MarqueeAnimationSpeed = 30
    $btnScan.Enabled = $false
    try {
        $script:ScanProc = Start-Bg -ScriptPath $script:ScanScript `
            -ScriptArgs @('-Root', $txtDrive.Text, '-MinSizeMB', ([int]$numMin.Value).ToString(), '-OutDir', $txtOut.Text) `
            -LogPath $script:ScanLog
    } catch {
        $lblScanStatus.Text = '启动失败: ' + $_.Exception.Message
        $btnScan.Enabled = $true
        $prgScan.MarqueeAnimationSpeed = 0
    }
})

$btnShowKey.Add_Click({
    $txtKey.UseSystemPasswordChar = -not $txtKey.UseSystemPasswordChar
    $btnShowKey.Text = if ($txtKey.UseSystemPasswordChar) { '显示' } else { '隐藏' }
})

function Start-Annotate {
    param([switch]$DryRun)
    if ($script:AnnProc -and -not $script:AnnProc.HasExited) { return }

    if (-not $chkOffline.Checked -and -not $DryRun) {
        if (-not $txtBase.Text.Trim())  { [void][System.Windows.Forms.MessageBox]::Show('请填写 API 端点。','缺少配置'); return }
        if (-not $txtKey.Text)          { [void][System.Windows.Forms.MessageBox]::Show('请填写 API Key。','缺少配置'); return }
        if (-not $txtModel.Text.Trim()) { [void][System.Windows.Forms.MessageBox]::Show('请填写模型名。','缺少配置'); return }
    }

    # 记住设置：勾选了就在跑之前把当前配置落盘（Key 加密）
    if ($chkRemember.Checked) { [void](Save-AiConfig) }

    # 通过环境变量把 key 传给子进程，避免出现在命令行里
    $env:MIGRATE_AI_BASE  = $txtBase.Text.Trim()
    $env:MIGRATE_AI_KEY   = $txtKey.Text
    $env:MIGRATE_AI_MODEL = $txtModel.Text.Trim()

    $json = Get-LatestScanJson
    if (-not $json) { [void][System.Windows.Forms.MessageBox]::Show('还没扫描报告，请先在「1. 扫描」页跑一次。','缺少报告'); return }
    $script:LastScanJson = $json

    $sargs = @('-ReportPath', $json, '-BatchSize', ([int]$numBatch.Value).ToString(), '-Limit', ([int]$numLimit.Value).ToString())
    if ($chkOffline.Checked) { $sargs += '-Offline' }
    if ($DryRun) { $sargs += '-DryRun' }

    $script:AnnOff = 0
    $logAnn.Clear()
    $lblAnnStatus.Text = if ($DryRun) { '生成预览…' } else { '标注中…' }
    $lblAnnStatus.ForeColor = [System.Drawing.Color]::FromArgb(200,110,0)
    $prgAnn.MarqueeAnimationSpeed = 30
    $btnAnn.Enabled = $false; $btnDry.Enabled = $false
    try {
        $script:AnnProc = Start-Bg -ScriptPath $script:AnnScript -ScriptArgs $sargs -LogPath $script:AnnLog
    } catch {
        $lblAnnStatus.Text = '启动失败: ' + $_.Exception.Message
        $btnAnn.Enabled = $true; $btnDry.Enabled = $true
        $prgAnn.MarqueeAnimationSpeed = 0
    }
}
$btnClearKey.Add_Click({
    if (-not (Test-Path -LiteralPath $script:CfgPath)) {
        [void][System.Windows.Forms.MessageBox]::Show('还没有保存过任何设置。', '提示'); return
    }
    if ([System.Windows.Forms.MessageBox]::Show(
        "将清除已保存的 API Key（端点与模型保留）。`n`n继续？", '确认清除', 'YesNo', 'Warning') -ne 'Yes') { return }
    $txtKey.Clear()
    $chkRemember.Checked = $false
    [void](Save-AiConfig)
    $lblAnnStatus.Text = '已清除保存的密钥；端点与模型仍保留。'
    $lblAnnStatus.ForeColor = [System.Drawing.Color]::FromArgb(0,128,64)
})

$btnTestConn.Add_Click({
    if ($chkRemember.Checked) { [void](Save-AiConfig) }
    $oldCur = $form.Cursor
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $lblAnnStatus.Text = '正在测试连接…'
    $lblAnnStatus.ForeColor = [System.Drawing.Color]::FromArgb(200,110,0)
    [System.Windows.Forms.Application]::DoEvents()
    try   { $r = Test-AiConnectionInline }
    finally { $form.Cursor = $oldCur }

    Append-Log $logAnn ("`r`n[测试连接]`r`n" + $r.Msg + "`r`n")
    foreach ($ln in ($r.Msg -split "`n")) {
        $lblAnnStatus.Text = $ln
        if ($ln.Trim()) { break }
    }
    if ($r.Ok) {
        $lblAnnStatus.ForeColor = [System.Drawing.Color]::FromArgb(0,128,64)
        $lblAnnStatus.Text = '连接成功 —— 端点/模型/Key 都可用，可以开始标注了。'
    } else {
        $lblAnnStatus.ForeColor = [System.Drawing.Color]::FromArgb(176,0,32)
        $lblAnnStatus.Text = '连接失败 —— 详情见下方日志。'
    }
})

$btnDry.Add_Click({ Start-Annotate -DryRun })
$btnAnn.Add_Click({ Start-Annotate })

$cmbFilter.Add_SelectedIndexChanged({ Refresh-List })

$btnRefreshState.Add_Click({ [void](Update-RowState) })

$btnClean.Add_Click({
    if ($script:ClnProc -and -not $script:ClnProc.HasExited) {
        [void][System.Windows.Forms.MessageBox]::Show('上一次清理还在进行中，请稍候。', '提示'); return
    }
    $checked = @($lv.CheckedItems | Where-Object { $_.Tag })
    if ($checked.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show("还没有勾选任何目录。`n`n提示：可点「全选可删」快速勾选可清理的项。", '没有待清理项')
        return
    }
    $f = Get-CleanableItems -Checked $checked
    if (@($f.Ok).Count -eq 0) {
        $why = (($f.Rejected | ForEach-Object { '· ' + $_.Reason }) | Select-Object -Unique) -join "`n"
        [void][System.Windows.Forms.MessageBox]::Show(
            ("勾选的 $($checked.Count) 项都不符合清理条件：`n`n$why`n`n" +
             "「清理」只对判定为「可删 DELETE」的目录生效。`n" +
             "可迁 / 待定 / 禁区 的目录请用「4. 执行迁移」处理，或保持勾选用于导出清单。"),
            '没有可清理的项')
        return
    }
    $ans = Show-CleanupConfirm -Items $f.Ok -Rejected $f.Rejected
    if (-not $ans) { return }
    if (Start-CleanJob -Mode $ans.Mode -Items $f.Ok) {
        Append-Log $logCln ("[{0}] 开始清理 {1} 项（{2}）`r`n" -f (Get-Date -Format 'HH:mm:ss'), @($f.Ok).Count,
            $(if ($ans.Mode -eq 'Permanent') { '永久删除' } else { '移入回收站' }))
    }
})

# F5 也能刷新（整窗快捷键）
$form.KeyPreview = $true
$form.Add_KeyDown({
    param($sender, $e)
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::F5) {
        [void](Update-RowState)
        $e.Handled = $true
    }
})

$btnSelDelete.Add_Click({
    foreach ($i in $lv.Items) { $i.Checked = ($i.Tag.Verdict -eq 'DELETE') }
    Update-Stat
})
$btnSelMigrate.Add_Click({
    foreach ($i in $lv.Items) { $i.Checked = ($i.Tag.Verdict -eq 'MIGRATE') }
    Update-Stat
})
$btnSelNone.Add_Click({
    foreach ($i in $lv.Items) { $i.Checked = $false }
    Update-Stat
})
$lv.Add_ItemChecked({ Update-Stat })

$btnExport.Add_Click({
    $checked = @($lv.CheckedItems | Where-Object { $_.Tag })
    if ($checked.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show('还没有勾选任何目录。','导出'); return }

    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $base  = Join-Path $script:ReportDir "decision-$stamp"
    $rows  = foreach ($ci in $checked) {
        [pscustomobject]@{
            Verdict = $ci.Tag.Verdict
            SizeGB  = $ci.Tag.SizeGB
            Path    = $ci.Tag.Path
            Identity= $ci.Tag.Identity
            Reason  = if ($ci.Tag.Reason) { $ci.Tag.Reason } else { $ci.Tag.RuleRea }
        }
    }
    $rows = @($rows)

    $rows | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath "$base.json" -Encoding UTF8
    $rows | Export-Csv -LiteralPath "$base.csv" -NoTypeInformation -Encoding UTF8

    # 人类可读 + 便于后续执行模块消费的纯路径清单
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add("# C 盘迁移决策清单  $stamp")
    [void]$lines.Add("# 共 {0} 项，合计 {1:N2} GB" -f $rows.Count, (($rows | Measure-Object SizeGB -Sum).Sum))
    [void]$lines.Add("")
    foreach ($v in @('DELETE','MIGRATE','REDIRECT','REVIEW')) {
        $g = @($rows | Where-Object { $_.Verdict -eq $v } | Sort-Object SizeGB -Descending)
        if ($g.Count -eq 0) { continue }
        [void]$lines.Add("# ===== $v  ({0} 项 / {1:N2} GB) =====" -f $g.Count, (($g | Measure-Object SizeGB -Sum).Sum))
        foreach ($r in $g) {
            if ($r.Identity) { [void]$lines.Add("#   $($r.Identity)") }
            [void]$lines.Add("#   $($r.Reason)")
            [void]$lines.Add($r.Path)
        }
        [void]$lines.Add("")
    }
    Set-Content -LiteralPath "$base.txt" -Value $lines -Encoding UTF8

    [void][System.Windows.Forms.MessageBox]::Show(
        ("已导出 $($rows.Count) 项，合计 {0:N2} GB`n`n$base.json`n$base.csv`n$base.txt" -f (($rows | Measure-Object SizeGB -Sum).Sum)),
        '导出完成')
    Start-Process explorer.exe $script:ReportDir
})

# ---- Tab 4 事件 ----
$btnDest.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = '选择目标盘上的父目录（最终路径 = 父目录\源文件夹名）'
    if ($dlg.ShowDialog() -eq 'OK') { $txtDest.Text = $dlg.SelectedPath }
})

$btnLoad.Add_Click({
    $checked = @($lv.CheckedItems | Where-Object { $_.Tag })
    if ($checked.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show("「3. 决策清单」里还没有勾选任何目录。`n`n提示：可先点「全选可迁」快速勾选。", '没有待执行项')
        return
    }
    $script:QueueItems = @($checked | ForEach-Object {
        [pscustomobject]@{ Source = $_.Tag.Path; DestinationRoot = $txtDest.Text.Trim(); Verdict = $_.Tag.Verdict }
    })
    $lvRun.Items.Clear()
    $i = 0; $sum = 0.0
    foreach ($q in $script:QueueItems) {
        $i++
        $it = New-Object System.Windows.Forms.ListViewItem([string]$i)
        [void]$it.SubItems.Add($q.Source)
        [void]$it.SubItems.Add('待执行')
        [void]$it.SubItems.Add('')
        [void]$lvRun.Items.Add($it)
    }
    foreach ($c in $checked) { $sum += [double]$c.Tag.SizeGB }
    $lblRunStatus.Text = ('已载入 {0} 项，合计 {1:N2} GB。建议先点「② 仅预检」确认无阻塞项。' -f $script:QueueItems.Count, $sum)
    $prgRun.Value = 0
    Append-Log $logRun ("[载入] {0} 项待执行`r`n" -f $script:QueueItems.Count)
})

$btnPre.Add_Click({
    if (@($script:QueueItems).Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show('请先点「① 载入勾选项」。', '提示'); return }
    if (-not $txtDest.Text.Trim()) { [void][System.Windows.Forms.MessageBox]::Show('请先填写「目标盘父目录」。', '缺少配置'); return }
    if (-not (Test-Path -LiteralPath $txtDest.Text.Trim())) { [void][System.Windows.Forms.MessageBox]::Show("目标盘父目录不存在：`n$($txtDest.Text.Trim())`n`n请先创建该目录。", '目录不存在'); return }
    Set-RunButtons $false
    if (Start-MigJob -Mode 'Preflight' -Items $script:QueueItems) { $lblRunStatus.Text = '预检中…（不做任何写操作）' }
    else { Set-RunButtons $true }
})

$btnRun.Add_Click({
    if (@($script:QueueItems).Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show('请先点「① 载入勾选项」。', '提示'); return }
    if (-not $txtDest.Text.Trim()) { [void][System.Windows.Forms.MessageBox]::Show('请先填写「目标盘父目录」。', '缺少配置'); return }
    if (-not (Test-Path -LiteralPath $txtDest.Text.Trim())) { [void][System.Windows.Forms.MessageBox]::Show("目标盘父目录不存在：`n$($txtDest.Text.Trim())`n`n请先创建该目录。", '目录不存在'); return }

    $msg = "即将把 $($script:QueueItems.Count) 个目录迁移到：`n$($txtDest.Text.Trim())`n`n" +
           "· 每项都先跑完整预检，不通过就跳过（不做任何写操作）`n" +
           "· 复制并校验通过后，才在原位置建立 Junction 并删除源目录`n" +
           "· 任何一项失败都不会破坏源目录`n" +
           "· 执行前请关闭相关程序，否则会被预检拦下`n`n确定开始吗？"
    if ([System.Windows.Forms.MessageBox]::Show($msg, '确认执行迁移', 'YesNo', 'Warning') -ne 'Yes') { return }
    Set-RunButtons $false
    if (Start-MigJob -Mode 'Migrate' -Items $script:QueueItems) { $lblRunStatus.Text = '执行中…' }
    else { Set-RunButtons $true }
})

$btnStop.Add_Click({
    if ($script:MigProc -and -not $script:MigProc.HasExited) {
        if ([System.Windows.Forms.MessageBox]::Show('确定中止？已完成的项会保留，未开始的项不会执行。', '确认中止', 'YesNo', 'Question') -eq 'Yes') {
            Stop-ChildTree $script:MigProc
    Stop-ChildTree $script:ClnProc
            Append-Log $logRun "`r`n[已请求中止]`r`n"
        }
    }
})

$btnUndo.Add_Click({
    if (-not $script:LastResult) { [void][System.Windows.Forms.MessageBox]::Show('还没有可回滚的执行记录。', '提示'); return }
    $items = @($script:LastResult.Results | Where-Object { $_.ManifestPath -and (Test-Path -LiteralPath ([string]$_.ManifestPath)) } |
        ForEach-Object { [pscustomobject]@{ Source = $_.Source; ManifestPath = $_.ManifestPath } })
    if ($items.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show('上次执行没有可回滚的项。', '提示'); return }
    $msg = "将回滚 $($items.Count) 项。`n`n" +
           "优先使用「重命名 / 补建链接」等零数据移动方案；`n" +
           "只有当链接已生效时才需要把数据搬回来。`n`n继续？"
    if ([System.Windows.Forms.MessageBox]::Show($msg, '确认回滚', 'YesNo', 'Warning') -ne 'Yes') { return }
    Set-RunButtons $false
    if (Start-MigJob -Mode 'Undo' -Items $items) { $lblRunStatus.Text = '回滚中…' }
    else { Set-RunButtons $true }
})

# ============================================================
#  轮询定时器
# ============================================================
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 400
$timer.Add_Tick({
    # --- 扫描 ---
    if ($script:ScanProc) {
        $txt = Read-NewLines -LogPath $script:ScanLog -Offset ([ref]$script:ScanOff)
        if ($txt) { Append-Log $logScan $txt }
        if ($script:ScanProc.HasExited) {
            $prgScan.MarqueeAnimationSpeed = 0
            $btnScan.Enabled = $true
            $code = $script:ScanProc.ExitCode
            $script:ScanProc.Dispose(); $script:ScanProc = $null
            $j = Get-LatestScanJson
            if ($j) {
                $lblScanStatus.Text = '扫描完成，已载入决策清单（切到「3. 决策清单」查看）。'
                $lblScanStatus.ForeColor = [System.Drawing.Color]::FromArgb(0,128,64)
                Load-List -JsonPath $j
                $tabs.SelectedIndex = 2
            } else {
                $lblScanStatus.Text = "扫描结束但未找到报告 (exit=$code)，请看下方日志。"
                $lblScanStatus.ForeColor = [System.Drawing.Color]::FromArgb(176,0,32)
            }
        }
    }
    # --- 标注 ---
    if ($script:AnnProc) {
        $txt = Read-NewLines -LogPath $script:AnnLog -Offset ([ref]$script:AnnOff)
        if ($txt) { Append-Log $logAnn $txt }
        if ($script:AnnProc.HasExited) {
            $prgAnn.MarqueeAnimationSpeed = 0
            $btnAnn.Enabled = $true; $btnDry.Enabled = $true
            $code = $script:AnnProc.ExitCode
            $script:AnnProc.Dispose(); $script:AnnProc = $null
            $a = Get-LatestAnnotatedJson
            if ($a) {
                $lblAnnStatus.Text = '标注完成，已载入决策清单。'
                $lblAnnStatus.ForeColor = [System.Drawing.Color]::FromArgb(0,128,64)
                Load-List -JsonPath $a
                $tabs.SelectedIndex = 2
            } else {
                $lblAnnStatus.Text = "标注结束(exit=$code)，未产生标注报告，请看下方日志。"
                $lblAnnStatus.ForeColor = [System.Drawing.Color]::FromArgb(176,0,32)
            }
        }
    }
})
$timer.Start()

function Stop-ChildTree {
    param($Proc)
    if (-not $Proc) { return }
    try { if ($Proc.HasExited) { return } } catch { return }
    # Process.Kill() 只杀本进程；用 taskkill /T 连子进程一起杀，否则会留下后台扫描进程
    try { & taskkill.exe /T /F /PID $Proc.Id 2>$null | Out-Null } catch {}
    try { $Proc.WaitForExit(5000) | Out-Null } catch {}
    try { if (-not $Proc.HasExited) { $Proc.Kill() } } catch {}
}

# ============================================================
#  迁移队列轮询（独立定时器，不动原定时器）
# ============================================================
$timer2 = New-Object System.Windows.Forms.Timer
$timer2.Interval = 600
$timer2.Add_Tick({
    if (-not $script:MigProc) { return }
    $txt = Read-NewLines -LogPath $script:MigLog -Offset ([ref]$script:MigOff)
    if ($txt) { Append-Log $logRun $txt }
    try {
        if (Test-Path -LiteralPath $script:MigProg) {
            $pg = Get-Content -LiteralPath $script:MigProg -Raw -Encoding UTF8 | ConvertFrom-Json
            $v = [int]$pg.Percent
            if ($v -ge 0 -and $v -le 100) { $prgRun.Value = $v }
            $leaf = Split-Path ([string]$pg.Source) -Leaf
            $lblRunStatus.Text = ('[{0}/{1}] {2} — {3}    成功 {4} / 失败 {5}' -f $pg.Index, $pg.Total, $pg.Phase, $leaf, $pg.Done, $pg.Failed)
        }
    } catch {}
    if ($script:MigProc.HasExited) {
        $code = $script:MigProc.ExitCode
        $script:MigProc.Dispose(); $script:MigProc = $null
        Set-RunButtons $true
        if (Test-Path -LiteralPath $script:MigResult) {
            try {
                $script:LastResult = Get-Content -LiteralPath $script:MigResult -Raw -Encoding UTF8 | ConvertFrom-Json
                Show-RunResults $script:LastResult
                $prgRun.Value = 100
                # 迁移/回滚刚改变了磁盘状态，自动刷新决策清单，避免列表还显示已搬走的目录
                [void](Update-RowState -Quiet)
            } catch { $lblRunStatus.Text = '结果文件解析失败，请看下方日志。' }
        } else {
            $lblRunStatus.Text = "执行结束（exit=$code）但没有产生结果文件，请看下方日志。"
        }
    }
})
$timer2.Start()

# ============================================================
#  清理队列轮询
# ============================================================
$timer3 = New-Object System.Windows.Forms.Timer
$timer3.Interval = 500
$timer3.Add_Tick({
    if (-not $script:ClnProc) { return }
    $txt = Read-NewLines -LogPath $script:ClnLog -Offset ([ref]$script:ClnOff)
    if ($txt) { Append-Log $logCln $txt }
    if ($script:ClnProc.HasExited) {
        $code = $script:ClnProc.ExitCode
        $script:ClnProc.Dispose(); $script:ClnProc = $null
        if (Test-Path -LiteralPath $script:ClnResult) {
            try {
                $res = Get-Content -LiteralPath $script:ClnResult -Raw -Encoding UTF8 | ConvertFrom-Json
                Append-Log $logCln ("`r`n[{0}] === 清理完成：成功 {1} / 失败 {2} / 跳过 {3}，释放 {4:N2} GB ===`r`n" -f `
                    (Get-Date -Format 'HH:mm:ss'), $res.Done, $res.Failed, $res.Skipped, ($res.FreedBytes / 1GB))
                if ([string]$res.Mode -eq 'Recycle') {
                    Append-Log $logCln "注意：内容已移入回收站，需清空回收站才会真正释放磁盘空间。`r`n"
                }
                # 清理改变了磁盘状态 -> 刷新决策清单
                [void](Update-RowState -Quiet)
            } catch {}
        } else {
            Append-Log $logCln ("`r`n[{0}] 清理结束（exit=$code）但没有产生结果文件。`r`n" -f (Get-Date -Format 'HH:mm:ss'))
        }
    }
})
$timer3.Start()

$form.Add_FormClosing({
    try {
        Stop-ChildTree $script:ScanProc
        Stop-ChildTree $script:AnnProc
        Stop-ChildTree $script:MigProc
    Stop-ChildTree $script:ClnProc
        Start-Sleep -Milliseconds 400
        # ⚠️ 这里必须用 for 语句，不能用 ForEach-Object 管道。
        # PowerShell 的 break 放进 ForEach-Object 的脚本块是非法的：它抛 BreakException，
        # try/catch 抓不住，会一路穿透到 WinForms 消息循环，弹出 .NET 未处理异常对话框。
        for ($i = 0; $i -lt 3; $i++) {
            if (Test-Path $script:TempDir) { Remove-Item $script:TempDir -Recurse -Force -ErrorAction SilentlyContinue }
            if (-not (Test-Path $script:TempDir)) { break }
            Start-Sleep -Milliseconds 300
        }
    } catch {}
})

# 双保险：ShowDialog 返回后再清一次（事件处理器里抛异常也不会留下垃圾）
$form.Add_Shown({})

# 启动时若已有报告，直接载入
# 取「扫描报告」与「标注报告」里更新的那一份：
# 否则重新扫描后，界面仍会显示基于旧扫描的标注结果。
$candAnn  = Get-LatestAnnotatedJson
$candScan = Get-LatestScanJson
$initJson = $null
if ($candAnn -and $candScan) {
    $initJson = if ((Get-Item $candAnn).LastWriteTime -ge (Get-Item $candScan).LastWriteTime) { $candAnn } else { $candScan }
} elseif ($candAnn) { $initJson = $candAnn } elseif ($candScan) { $initJson = $candScan }
if ($initJson) {
    Load-List -JsonPath $initJson
    Append-Log $logScan ("[启动] 已载入既有报告: " + (Split-Path $initJson -Leaf) + "`r`n")
}

# ============================================================
#  锚定修正
#  WinForms 的 Anchor 会把「控件到容器边缘的距离」在设置 Anchor 的那一刻记下来。
#  但在 Show() 之前容器尺寸还没最终确定，于是距离算错，窗体一显示控件就跑到天边去。
#  修法：记录每个控件的设计尺寸，等窗体真正显示（Shown）后再恢复尺寸并重设 Anchor。
# ============================================================
$script:AnchorFix = New-Object System.Collections.ArrayList
function Add-AnchorFix {
    param($Parent)
    foreach ($c in $Parent.Controls) {
        [void]$script:AnchorFix.Add([pscustomobject]@{ C = $c; B = $c.Bounds; A = $c.Anchor })
        if ($c.Controls.Count -gt 0) { Add-AnchorFix $c }
    }
}
Add-AnchorFix $form

$form.Add_Shown({
    $none = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left
    foreach ($r in $script:AnchorFix) {
        try {
            $r.C.Anchor = $none     # 先解除锚定，避免恢复 Bounds 时被拉扯
            $r.C.Bounds = $r.B      # 恢复设计尺寸
            $r.C.Anchor = $r.A      # 重新锚定（此时容器尺寸已正确，距离才准）
        } catch {}
    }
})

# 启动时载入上次保存的 AI 设置
$cfgState = Load-AiConfig
$cfgMsg = switch ($cfgState) {
    'ok'      { '已载入上次保存的 AI 设置。' }
    'keyfail' { '已载入端点与模型，但保存的 API Key 解不开（换过 Windows 账户或机器？），请重新输入。' }
    'fail'    { 'AI 设置文件读取失败，已忽略。' }
    default   { '' }
}
if ($cfgMsg) { Append-Log $logAnn ("[{0}] {1}`r`n" -f (Get-Date -Format 'HH:mm:ss'), $cfgMsg) }

# 启动时载入最近一次迁移结果 -> 「回滚上次执行」重启后依然可用
if (Test-Path -LiteralPath $script:MigDir) {
    $lastRes = @(Get-ChildItem -LiteralPath $script:MigDir -Filter 'result-*.json' -ErrorAction SilentlyContinue |
                 Sort-Object LastWriteTime -Descending | Select-Object -First 1)
    if ($lastRes.Count -gt 0) {
        try {
            $script:LastResult = Get-Content -LiteralPath $lastRes[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            Show-RunResults $script:LastResult
            $lblRunStatus.Text = ('已载入上次执行结果（{0}）：成功 {1} / 失败 {2} / 跳过 {3}' -f $script:LastResult.Mode, $script:LastResult.Done, $script:LastResult.Failed, $script:LastResult.Skipped)
            [void](Update-RowState -Quiet)
        } catch {}
    }
}

[void]$form.ShowDialog()

# 收尾（防事件处理器未生效）
Stop-ChildTree $script:ScanProc
Stop-ChildTree $script:AnnProc
Stop-ChildTree $script:MigProc
Stop-ChildTree $script:ClnProc
Start-Sleep -Milliseconds 300
Remove-Item $script:TempDir -Recurse -Force -ErrorAction SilentlyContinue
