$ErrorActionPreference = 'Continue'
$Report = Join-Path $PSScriptRoot 'report'
$Latin1 = [System.Text.Encoding]::GetEncoding(28591)   # ISO-8859-1

function Repair-Mojibake {
    param([string]$s)
    if ([string]::IsNullOrEmpty($s)) { return $s }
    # 只有出现 Latin-1 补充区字符才可能是 mojibake；正常中文不含这类字符
    if ($s -notmatch '[\u00C0-\u00FF]') { return $s }
    try {
        # mojibake 的本质：UTF-8 字节被当 Latin-1 解码。
        # 反向操作：把字符按 Latin-1 编回字节，再按 UTF-8 解码。
        $bytes = $Latin1.GetBytes($s)
        $fixed = [System.Text.Encoding]::UTF8.GetString($bytes)
        if ($fixed -match '[\u4e00-\u9fa5]') { return $fixed }   # 修出中文才算成功
    } catch {}
    return $s
}

Write-Host ""
Write-Host ("=" * 74)
Write-Host " 修复标注文件里的编码乱码"
Write-Host ("=" * 74)

# ---------- 1. 清掉被 mock 污染的缓存 ----------
$cachePath = Join-Path $Report 'ai-cache.json'
if (Test-Path $cachePath) {
    Remove-Item $cachePath -Force
    Write-Host "  已删除被 mock 污染的 ai-cache.json"
}

# ---------- 2. 找出所有标注文件，修复其中的乱码 ----------
$files = @(Get-ChildItem -LiteralPath $Report -Filter 'annotated-*.json' | Sort-Object LastWriteTime -Descending)
$repairedFiles = @()

foreach ($f in $files) {
    $rows = @((Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json))
    $fixedCount = 0
    foreach ($r in $rows) {
        foreach ($field in @('Identity','AiReason','AiRisk')) {
            $v = [string]$r.$field
            if ($v) {
                $nv = Repair-Mojibake $v
                if ($nv -ne $v) { $r.$field = $nv; $fixedCount++ }
            }
        }
    }
    if ($fixedCount -gt 0) {
        $rows | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $f.FullName -Encoding UTF8
        Write-Host ("  修复 {0}：{1} 个字段" -f $f.Name, $fixedCount)
        $repairedFiles += $f.FullName
    } else {
        Write-Host ("  跳过 {0}：无需修复（或无 AI 数据）" -f $f.Name)
    }
    # CSV 也同步修一遍
    $csv = [System.IO.Path]::ChangeExtension($f.FullName, '.csv')
    if (Test-Path $csv) {
        $crows = @(Import-Csv -LiteralPath $csv)
        $cfixed = 0
        foreach ($cr in $crows) {
            foreach ($field in @('Identity','AiReason','AiRisk')) {
                $v = [string]$cr.$field
                if ($v) { $nv = Repair-Mojibake $v; if ($nv -ne $v) { $cr.$field = $nv; $cfixed++ } }
            }
        }
        if ($cfixed -gt 0) {
            $crows | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
            Write-Host ("          同步修复 CSV：{0} 个字段" -f $cfixed)
        }
    }
}

# ---------- 3. 从修复后的数据重建缓存，避免你重跑时再花一次 API 钱 ----------
if ($repairedFiles.Count -gt 0) {
    $src = $repairedFiles[0]     # 最新的那份
    $rows = @((Get-Content -LiteralPath $src -Raw -Encoding UTF8 | ConvertFrom-Json))
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $cache = @{}
    foreach ($r in $rows) {
        if (-not $r.Identity) { continue }
        # 缓存键与脚本保持一致： 脱敏路径 | SizeGB | 规则判定
        $anon = [string]$r.Path -replace '(?i)^([A-Z]:\\Users\\)[^\\]+', '$1__USER__'
        $key = "{0}|{1}|{2}" -f $anon, $r.SizeGB, $r.RuleVerdict
        $h = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($key))
        $hex = ($h | ForEach-Object { $_.ToString('x2') }) -join ''
        $cache[$hex] = [pscustomobject]@{
            path       = $anon
            identity   = [string]$r.Identity
            suggestion = [string]$r.AiSuggestion
            confidence = [string]$r.AiConfidence
            reason     = [string]$r.AiReason
            risk       = [string]$r.AiRisk
        }
    }
    $cache | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $cachePath -Encoding UTF8
    Write-Host ("  已重建缓存：{0} 条（来源 {1}）" -f $cache.Count, (Split-Path $src -Leaf))
}

Write-Host ""
Write-Host " 完成。"
