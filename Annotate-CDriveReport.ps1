#Requires -Version 5.1
<#
.SYNOPSIS
    C 盘迁移报告 AI 标注层（阶段 2）

.DESCRIPTION
    读取 Scan-CDrive.ps1 生成的扫描报告，只把「需要语义判断」的目录元数据
    发给大模型，让它识别每个目录是什么、并给出人可读的判断依据。

    ⚠️ 权限边界（硬性设计，代码强制）：
      AI 没有「批准权」，只有「否决权」。
        · AI 不能把规则判定升级为更激进的操作
        · AI 可以把规则判定降级（例如把 DELETE 拉回 REVIEW = 建议别删）
        · AI 的 suggestion 若比规则更激进，只作为展示信息，不改变判定
      激进程度排序：keep(0) < review(1) < migrate(2) < delete(3)

    失败降级：任何网络/解析错误都不会中断流程，该目录标记为 AiStatus=failed，
    保留原规则判定。可加 -Offline 完全跳过 API，退回纯规则模式。

.PARAMETER ReportPath
    Scan-CDrive.ps1 生成的 JSON 报告路径。省略则自动取 report 目录下最新的一份。

.PARAMETER ApiBase
    API 基址，默认读环境变量 MIGRATE_AI_BASE
    例：https://api.deepseek.com/v1   /   https://api.openai.com/v1

.PARAMETER ApiKey
    API Key，默认读环境变量 MIGRATE_AI_KEY（推荐用环境变量，不要写进命令行）

.PARAMETER Model
    模型名，默认读环境变量 MIGRATE_AI_MODEL

.PARAMETER ApiStyle
    openai（/chat/completions）或 anthropic（/messages），默认 openai

.PARAMETER BatchSize
    每批发送的目录条数，默认 15

.PARAMETER Limit
    最多标注多少条（按体积从大到小），默认 0 = 全部

.PARAMETER DryRun
    只打印将要发送的内容，不调用 API、不产生费用

.PARAMETER Offline
    完全离线：不调用 API，仅输出纯规则报告

.PARAMETER NoCache
    忽略本地缓存（缓存文件 ai-cache.json，按 路径+体积+判定 做 SHA256）

.PARAMETER NoAnonymize
    不脱敏。默认会把用户名替换为 __USER__ 后再发送

.EXAMPLE
    $env:MIGRATE_AI_BASE  = 'https://api.deepseek.com/v1'
    $env:MIGRATE_AI_KEY   = 'sk-xxxx'
    $env:MIGRATE_AI_MODEL = 'deepseek-chat'
    .\Annotate-CDriveReport.ps1 -DryRun          # 先看要发什么
    .\Annotate-CDriveReport.ps1                  # 正式标注
#>
[CmdletBinding()]
param(
    [string]$ReportPath,
    [string]$ApiBase   = $env:MIGRATE_AI_BASE,
    [string]$ApiKey    = $env:MIGRATE_AI_KEY,
    [string]$Model     = $env:MIGRATE_AI_MODEL,
    [ValidateSet('openai','anthropic')]
    [string]$ApiStyle  = 'openai',
    [string]$ChatPath,
    [int]$BatchSize    = 15,
    [int]$Limit        = 0,
    [int]$TimeoutSec   = 120,
    [double]$Temperature = -1,   # -1 = 不发送 temperature 字段（GPT-5 等模型只接受默认值）
    [switch]$DryRun,
    [switch]$Offline,
    [switch]$NoCache,
    [switch]$NoAnonymize
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ============================================================
#  激进程度阶梯（AI 只能往低处走）
#  注意：PowerShell 哈希键不区分大小写，故统一用小写，查表时 .ToLower()
# ============================================================
$script:Rank = @{
    'block'   = 0
    'already' = 0
    'keep'    = 0
    'review'  = 1
    'migrate' = 2
    'delete'  = 3
}

# 送审范围：只送这些判定。BLOCK / ALREADY 绝不送审（AI 无权触碰）
$script:Sendable = @('REVIEW','MIGRATE','DELETE')

if ($ReportPath -and -not (Test-Path -LiteralPath $ReportPath)) {
    throw "报告文件不存在：$ReportPath`n请先运行 Scan-CDrive.ps1，或用 -ReportPath 指定正确的 JSON 报告。"
}
$script:WorkDir = if ($ReportPath) { Split-Path -Parent (Resolve-Path $ReportPath).Path } else { Join-Path (Get-Location).Path 'report' }

# ============================================================
#  1. 定位报告
# ============================================================
if (-not $ReportPath) {
    $cand = @(Get-ChildItem -LiteralPath $script:WorkDir -Filter 'cdrive-scan-*.json' -EA SilentlyContinue |
              Sort-Object LastWriteTime -Descending)
    if ($cand.Count -eq 0) {
        throw "在 $($script:WorkDir) 下找不到 cdrive-scan-*.json，请先运行 Scan-CDrive.ps1"
    }
    $ReportPath = $cand[0].FullName
}
Write-Host ""
Write-Host ("=" * 78)
Write-Host " C 盘迁移报告 -- AI 标注层（阶段 2）"
Write-Host ("=" * 78)
Write-Host (" 报告文件 : {0}" -f $ReportPath)

$raw  = Get-Content -LiteralPath $ReportPath -Raw -Encoding UTF8
$parsed = $raw | ConvertFrom-Json
$data = @($parsed)
Write-Host (" 目录总数 : {0}" -f $data.Count)

# ============================================================
#  2. 筛出送审项
# ============================================================
$sendable = @($data | Where-Object { $script:Sendable -contains $_.Verdict })
$sendable = @($sendable | Sort-Object SizeBytes -Descending)
if ($Limit -gt 0) { $sendable = @($sendable | Select-Object -First $Limit) }

$byVerdict = @($sendable | Group-Object Verdict | ForEach-Object { "{0}={1}" -f $_.Name, $_.Count })
Write-Host (" 送审项   : {0}  ({1})" -f $sendable.Count, ($byVerdict -join ', '))
Write-Host (" 不送审   : BLOCK / ALREADY 一律不发给 AI")
Write-Host ""

if ($sendable.Count -eq 0) {
    Write-Host "没有需要标注的目录。"
    exit 0
}

# ============================================================
#  3. 脱敏 + 构造送审载荷
# ============================================================
function Get-AnonPath {
    param([string]$Path)
    if ($NoAnonymize) { return $Path }
    $p = $Path
    $p = $p -replace '(?i)^([A-Z]:\\Users\\)[^\\]+', '$1__USER__'
    return $p
}

$payloadItems = @(foreach ($d in $sendable) {
    [pscustomobject]@{
        path         = (Get-AnonPath $d.Path)
        sizeGB       = $d.SizeGB
        files        = $d.Files
        ruleVerdict  = $d.Verdict
        ruleReason   = $d.Reason
        topExt       = $d.TopExtensions
        hasSqliteWal = [bool]$d.HasWal
        lockedFiles  = $d.LockedFiles
    }
})

# ============================================================
#  4. 缓存
# ============================================================
# 脱敏路径 -> 真实路径 映射（AI 会原样回传脱敏路径，合并时必须还原）
$anonToReal = @{}
foreach ($d in $sendable) {
    $a = Get-AnonPath $d.Path
    if (-not $anonToReal.ContainsKey($a)) { $anonToReal[$a] = $d.Path }
}
$cachePath = Join-Path $script:WorkDir 'ai-cache.json'
$cache = @{}
if (-not $NoCache -and (Test-Path -LiteralPath $cachePath)) {
    try {
        $c = Get-Content -LiteralPath $cachePath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $c.PSObject.Properties) { $cache[$p.Name] = $p.Value }
        Write-Host (" 缓存命中 : 已载入 {0} 条历史结果" -f $cache.Count)
    } catch { $cache = @{} }
}

function Get-CacheKey {
    param($Item)
    $s = "{0}|{1}|{2}" -f $Item.path, $Item.sizeGB, $Item.ruleVerdict
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $h = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($s))
    ($h | ForEach-Object { $_.ToString('x2') }) -join ''
}

# ============================================================
#  5. 提示词
# ============================================================
$systemPrompt = @'
你是 Windows 磁盘空间分析专家。用户会给你一批目录的元数据，你需要识别每个目录「是什么」，并给出人类可读的判断依据。

【严格约束】
1. 只依据提供的元数据判断。信息不足时 confidence 必须填 "low"，不要臆测。
2. 你没有批准权，只有否决权。你可以认为某个操作过于激进（例如认为不该删），但绝不能建议比原判定更激进的操作。
3. 涉及 Windows 系统目录、驱动程序、Program Files 下微软组件、UWP 应用数据、杀毒或安全软件，一律建议 "keep"。
4. 判断不了就填 "review"，不要猜。宁可保守。
5. 输出必须是纯 JSON 数组，禁止任何解释文字、禁止 markdown 代码块标记。

【输出格式】每个输入项对应一个元素，path 必须原样返回：
[
  {
    "path": "原样返回的路径",
    "identity": "这个目录是什么，中文，15 字以内",
    "suggestion": "keep | review | delete | migrate",
    "confidence": "high | medium | low",
    "reason": "判断依据，中文，40 字以内",
    "risk": "误操作的后果，中文，20 字以内"
  }
]
'@

$userPromptHeader = '请分析以下目录。只输出 JSON 数组，不要任何其他内容。'

# ============================================================
#  6. 调用 API
# ============================================================
function Get-Endpoint {
    $p = if ($ChatPath) { $ChatPath } elseif ($ApiStyle -eq 'anthropic') { '/messages' } else { '/chat/completions' }
    return ($ApiBase.TrimEnd('/') + $p)
}

function Test-ApiConfig {
    $missing = @()
    if (-not $ApiBase) { $missing += 'ApiBase (环境变量 MIGRATE_AI_BASE)' }
    if (-not $ApiKey)  { $missing += 'ApiKey  (环境变量 MIGRATE_AI_KEY)' }
    if (-not $Model)   { $missing += 'Model   (环境变量 MIGRATE_AI_MODEL)' }
    if ($missing.Count -gt 0) {
        throw ("缺少必要配置：`n  - " + ($missing -join "`n  - ") +
               "`n`n示例：`n  `$env:MIGRATE_AI_BASE='https://api.deepseek.com/v1'`n  `$env:MIGRATE_AI_KEY='sk-xxx'`n  `$env:MIGRATE_AI_MODEL='deepseek-chat'")
    }
}

function Invoke-AiBatch {
    param([string]$UserPrompt)

    $uri = Get-Endpoint

    if ($ApiStyle -eq 'anthropic') {
        $body = @{
            model      = $Model
            max_tokens = 4096
            system     = $systemPrompt
            messages   = @(@{ role = 'user'; content = $UserPrompt })
        }
        if ($Temperature -ge 0) { $body['temperature'] = $Temperature }
        $headers = @{ 'x-api-key' = $ApiKey; 'anthropic-version' = '2023-06-01' }
    } else {
        $body = @{
            model    = $Model
            messages = @(
                @{ role = 'system'; content = $systemPrompt }
                @{ role = 'user';   content = $UserPrompt }
            )
        }
        # 默认不发送 temperature：GPT-5 等推理模型只接受默认值，传 0 会被 400 拒绝
        if ($Temperature -ge 0) { $body['temperature'] = $Temperature }
        $headers = @{ Authorization = "Bearer $ApiKey" }
    }

    $json  = $body | ConvertTo-Json -Depth 10 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)

    # ⚠️ 这里绝不能用 Invoke-RestMethod：
    #    PowerShell 5.1 在服务端 Content-Type 不带 charset 时，会按 ISO-8859-1 解码响应体，
    #    中文会全部变成 "åæ¶ç«" 这种 mojibake，而且会被写进结果文件、在界面上显示为乱码。
    #    必须自己取原始字节、显式按 UTF-8 解码。
    $webResp = Invoke-WebRequest -Uri $uri -Method Post -Headers $headers -Body $bytes `
               -ContentType 'application/json; charset=utf-8' -TimeoutSec $TimeoutSec -UseBasicParsing
    $rawText = [System.Text.Encoding]::UTF8.GetString($webResp.RawContentStream.ToArray())
    $resp = $rawText | ConvertFrom-Json

    $content = $null
    try {
        if ($resp.choices) {
            $content = $resp.choices[0].message.content
        } elseif ($resp.content) {
            if ($resp.content -is [string]) { $content = $resp.content }
            else { $content = ($resp.content | Where-Object { $_.type -eq 'text' } | Select-Object -First 1).text }
        }
    } catch {}

    if (-not $content) { throw "API 返回中没有可解析的文本内容" }
    if ($content -isnot [string]) { $content = ($content -join '') }

    # 防御：检出「UTF-8 被当 Latin-1 解码」的典型特征。真出现说明编码处理又被绕过了，
    # 宁可在这里明确报警，也不要把乱码静默写进结果文件。
    $mojoHits = ([regex]::Matches($content, '[\u00C2-\u00C3][\u0080-\u00BF]|[\u00E4-\u00E9][\u0080-\u00BF]{2}')).Count
    if ($mojoHits -ge 3) {
        Write-Host "  [警告] 响应疑似编码错乱（检出 $mojoHits 处 mojibake 特征），请检查 API 的 Content-Type" -ForegroundColor Yellow
    }

    $t = $content.Trim()
    $t = $t -replace '(?s)^\s*```[a-zA-Z]*\s*', ''
    $t = $t -replace '(?s)```\s*$', ''
    $t = $t.Trim()

    $i = $t.IndexOf('['); $j = $t.LastIndexOf(']')
    if ($i -ge 0 -and $j -gt $i) { $t = $t.Substring($i, $j - $i + 1) }

    return ($t | ConvertFrom-Json)
}

# ============================================================
#  7. 主循环
# ============================================================
$annotations = @{}
$failed      = New-Object System.Collections.ArrayList
$fromCache   = 0

$todo = New-Object System.Collections.ArrayList
foreach ($item in $payloadItems) {
    $k = Get-CacheKey $item
    if (-not $NoCache -and $cache.ContainsKey($k)) {
        $o = $cache[$k]
        $real = if ($anonToReal.ContainsKey($item.path)) { $anonToReal[$item.path] } else { $item.path }
        $annotations[$real] = $o
        $fromCache++
    } else {
        [void]$todo.Add([pscustomobject]@{ Key = $k; Item = $item })
    }
}
Write-Host (" 缓存复用 : {0} 条；待请求 : {1} 条" -f $fromCache, $todo.Count)

if ($Offline) {
    Write-Host ""
    Write-Host " [Offline 模式] 跳过所有 AI 调用，仅输出纯规则报告。"
}
elseif ($DryRun) {
    Write-Host ""
    Write-Host ("=" * 78)
    Write-Host " [DryRun] 将要发送的内容（不调用 API、不产生费用）"
    Write-Host ("=" * 78)
    Write-Host ""
    Write-Host "--- system prompt ---"
    Write-Host $systemPrompt
    $preview = @($todo | Select-Object -First ([math]::Max($BatchSize,1)))
    Write-Host ("--- user prompt（第 1 批示范，共 {0} 条待请求，每批 {1} 条）---" -f $todo.Count, $BatchSize)
    Write-Host $userPromptHeader
    Write-Host ((@($preview | ForEach-Object { $_.Item })) | ConvertTo-Json -Depth 5)
    Write-Host ""
    Write-Host (" 目标端点 : {0}" -f (Get-Endpoint))
    Write-Host (" 模型     : {0}" -f $Model)
    Write-Host (" 脱敏     : {0}" -f $(if ($NoAnonymize) { '关闭（发送真实路径）' } else { '开启（用户名 -> __USER__）' }))
    Write-Host ""
    exit 0
}
else {
    Test-ApiConfig
    $total = [math]::Ceiling($todo.Count / $BatchSize)
    $n = 0
    for ($i = 0; $i -lt $todo.Count; $i += $BatchSize) {
        $n++
        $end = [math]::Min($i + $BatchSize - 1, $todo.Count - 1)
        $batch = @($todo[$i..$end])
        Write-Host ("`n [批次 {0}/{1}] {2} 条 ..." -f $n, $total, $batch.Count) -NoNewline

        $userPrompt = $userPromptHeader + "`n`n" + ((@($batch | ForEach-Object { $_.Item })) | ConvertTo-Json -Depth 5)

        $result = $null
        foreach ($attempt in 1..2) {
            try { $result = Invoke-AiBatch -UserPrompt $userPrompt; break }
            catch {
                if ($attempt -eq 2) {
                    Write-Host ("  失败: {0}" -f $_.Exception.Message)
                    foreach ($b in $batch) { [void]$failed.Add($b.Item.path) }
                } else { Start-Sleep -Seconds 3 }
            }
        }
        if (-not $result) { continue }

        $returned = @{}
        foreach ($r in @($result)) { if ($r.path) { $returned[[string]$r.path] = $r } }

        $ok = 0
        foreach ($b in $batch) {
            $p = $b.Item.path
            $real = if ($anonToReal.ContainsKey($p)) { $anonToReal[$p] } else { $p }
            if ($returned.ContainsKey($p)) {
                $annotations[$real] = $returned[$p]
                $cache[$b.Key] = $returned[$p]
                $ok++
            } else { [void]$failed.Add($real) }
        }
        Write-Host ("  已标注 {0}/{1}" -f $ok, $batch.Count)
    }

    if (-not $NoCache) {
        try { $cache | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $cachePath -Encoding UTF8 } catch {}
    }
}

# ============================================================
#  8. 合并：强制「AI 只能降级」
# ============================================================
$final = foreach ($d in $data) {
    $ai = $annotations[$d.Path]
    $ruleRank = $script:Rank[([string]$d.Verdict).ToLower()]

    $verdict  = $d.Verdict
    $veto     = $false
    $identity = ''; $aiReason = ''; $aiRisk = ''; $aiConf = ''; $aiSugg = ''
    $aiStatus = if ($Offline) { 'offline' } elseif ($ai) { 'ok' } else { 'not-sent' }

    if ($ai) {
        $identity = [string]$ai.identity
        $aiReason = [string]$ai.reason
        $aiRisk   = [string]$ai.risk
        $aiConf   = [string]$ai.confidence
        $aiSugg   = [string]$ai.suggestion
        if ($ai._fromCache) { $aiStatus = 'cached' }

        $aiRank = $script:Rank[([string]$ai.suggestion).ToLower()]
        if ($null -ne $aiRank -and $null -ne $ruleRank -and $aiRank -lt $ruleRank) {
            $verdict = 'REVIEW'   # AI 更保守 -> 行使否决权
            $veto    = $true
        }
        # AI 更激进 -> 忽略，仅保留 suggestion 作为展示信息
    }

    [pscustomobject]@{
        FinalVerdict  = $verdict
        RuleVerdict   = $d.Verdict
        AiVeto        = $veto
        AiStatus      = $aiStatus
        Path          = $d.Path
        SizeGB        = $d.SizeGB
        SizeBytes     = $d.SizeBytes
        Files         = $d.Files
        Identity      = $identity
        AiReason      = $aiReason
        AiRisk        = $aiRisk
        AiSuggestion  = $aiSugg
        AiConfidence  = $aiConf
        RuleReason    = $d.Reason
        TopExtensions = $d.TopExtensions
        HasWal        = $d.HasWal
        LockedFiles   = $d.LockedFiles
    }
}
$final = @($final)

# ============================================================
#  9. 报告
# ============================================================
$order = @('DELETE','MIGRATE','REDIRECT','REVIEW','ALREADY','BLOCK')
$labels = @{
    DELETE   = '可删   DELETE   —— 直接清理，无需迁移'
    MIGRATE  = '可迁   MIGRATE  —— 适合 Junction 迁移'
    REDIRECT = '重定向 REDIRECT —— 用系统「位置」功能'
    REVIEW   = '待定   REVIEW   —— 需人工确认'
    ALREADY  = '已迁   ALREADY  —— 已经是链接'
    BLOCK    = '禁区   BLOCK    —— 绝对不可迁移'
}

$okCount = @($final | Where-Object { $_.AiStatus -in @('ok','cached') }).Count
$vetoCount = @($final | Where-Object { $_.AiVeto }).Count

Write-Host ""
Write-Host ("=" * 78)
if ($Offline) { Write-Host " 汇总（纯规则模式，未调用 AI）" } else { Write-Host " 汇总（规则判定 + AI 标注）" }
Write-Host ("=" * 78)
Write-Host (" 标注成功 {0} 条 / 失败 {1} 条 / 缓存复用 {2} 条 / AI 行使否决 {3} 条" -f `
    $okCount, $failed.Count, $fromCache, $vetoCount)

$grand = [int64]0
foreach ($v in $order) {
    $set = @($final | Where-Object { $_.FinalVerdict -eq $v } | Sort-Object SizeBytes -Descending)
    $sum = [int64](($set | Measure-Object SizeBytes -Sum).Sum); if (-not $sum) { $sum = 0 }
    if ($v -in @('DELETE','MIGRATE','REDIRECT')) { $grand += $sum }

    Write-Host ""
    Write-Host ("-" * 78)
    Write-Host ("[{0}]  {1} 项 / {2:N2} GB" -f $labels[$v], $set.Count, ($sum/1GB))
    Write-Host ("-" * 78)
    if ($set.Count -eq 0) { Write-Host "  (无)"; continue }

    foreach ($r in $set) {
        $tag = if ($r.AiVeto) { '   [AI 否决]' } elseif ($r.AiStatus -eq 'failed') { '   [AI 失败]' } else { '' }
        Write-Host ("  {0,9:N2} GB  {1}{2}" -f $r.SizeGB, $r.Path, $tag)
        if ($r.Identity) {
            Write-Host ("  {0}是什么: {1}   (置信度 {2})" -f (' ' * 12), $r.Identity, $r.AiConfidence)
            Write-Host ("  {0}AI 建议: {1}   依据: {2}" -f (' ' * 12), $r.AiSuggestion, $r.AiReason)
            if ($r.AiRisk) { Write-Host ("  {0}误删后果: {1}" -f (' ' * 12), $r.AiRisk) }
        }
        Write-Host ("  {0}规则依据: {1}" -f (' ' * 12), $r.RuleReason)
    }
}

Write-Host ""
Write-Host ("=" * 78)
Write-Host (" 可操作空间合计: {0:N2} GB" -f ($grand/1GB))
Write-Host ("=" * 78)

# ---- 导出 ----
$stamp   = (Get-Date).ToString('yyyyMMdd-HHmmss')
$jsonOut = Join-Path $script:WorkDir "annotated-$stamp.json"
$csvOut  = Join-Path $script:WorkDir "annotated-$stamp.csv"

$final | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $jsonOut -Encoding UTF8
$final | Select-Object FinalVerdict, RuleVerdict, AiVeto, AiStatus, SizeGB, Path, Identity, AiSuggestion, AiConfidence, AiReason, AiRisk |
    Export-Csv -LiteralPath $csvOut -NoTypeInformation -Encoding UTF8

foreach ($v in $order) {
    $set = @($final | Where-Object { $_.FinalVerdict -eq $v } | Sort-Object SizeBytes -Descending)
    if ($set.Count -eq 0) { continue }
    $lp = Join-Path $script:WorkDir ("ann-list-{0}.txt" -f $v.ToLower())
    $lines = foreach ($r in $set) {
        "# {0,8:N2} GB  {1}" -f $r.SizeGB, $r.Identity
        "#   规则: {0}" -f $r.RuleReason
        if ($r.AiReason) { "#   AI  : {0}（建议 {1} / 置信度 {2}）" -f $r.AiReason, $r.AiSuggestion, $r.AiConfidence }
        $r.Path
    }
    Set-Content -LiteralPath $lp -Value $lines -Encoding UTF8
}

$vetoed = @($final | Where-Object { $_.AiVeto })
if ($vetoed.Count -gt 0) {
    $lines = foreach ($r in $vetoed) {
        "# {0,8:N2} GB  规则判 {1} -> AI 拉回 REVIEW" -f $r.SizeGB, $r.RuleVerdict
        "#   {0}" -f $r.AiReason
        $r.Path
    }
    Set-Content -LiteralPath (Join-Path $script:WorkDir 'ai-veto.txt') -Value $lines -Encoding UTF8
}

if ($failed.Count -gt 0) {
    Set-Content -LiteralPath (Join-Path $script:WorkDir 'ai-failed.txt') -Value $failed -Encoding UTF8
}

Write-Host ""
Write-Host " 已导出："
Write-Host ("   JSON : {0}" -f $jsonOut)
Write-Host ("   CSV  : {0}" -f $csvOut)
Write-Host ("   清单 : {0}\ann-list-*.txt" -f (Resolve-Path $script:WorkDir).Path)
Write-Host ("   缓存 : {0}" -f $cachePath)
if ($vetoed.Count -gt 0) { Write-Host ("   否决 : {0}\ai-veto.txt" -f (Resolve-Path $script:WorkDir).Path) }
if ($failed.Count -gt 0) { Write-Host ("   失败 : {0}\ai-failed.txt" -f (Resolve-Path $script:WorkDir).Path) }
Write-Host ""
Write-Host " 本工具只做扫描、分级和标注，不执行任何删除或迁移操作。"
Write-Host ""
