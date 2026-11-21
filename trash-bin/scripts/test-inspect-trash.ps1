param([Parameter(Mandatory = $true)][string]$WorkRoot)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$inspect=Join-Path $PSScriptRoot 'inspect-trash.ps1'
$move=Join-Path $PSScriptRoot 'move-to-trash.ps1'
$fixture=Join-Path ([IO.Path]::GetFullPath($WorkRoot)) ('fixture-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
$manifest=Join-Path $fixture 'selection.json'
$passed=0
function Check([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:passed++
}
function Audit { & $inspect -Root $fixture -Manifest $manifest | ConvertFrom-Json }
function Save($Files) { @{files=@($Files)} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifest -Encoding utf8 }
function Reject([scriptblock]$Action) {
    $caught=$false
    try { & $Action | Out-Null } catch { $caught=$true }
    Check $caught '应当拒绝的操作被接受。'
}
Set-Content -LiteralPath (Join-Path $fixture 'unused.txt') -Value '来自旧任务的隔离弃用样本'
$first=Audit
Check ($first.manifestState -eq 'missing') '未正确识别缺失清单。'
Check ($first.counts.unregistered_needs_review -eq 1) '缺失清单时遗漏真实文件。'
Check (Test-Path -LiteralPath (Join-Path $fixture 'unused.txt')) '调查修改了文件。'
$emptyMove=& $move -Root $fixture -Manifest $manifest -Apply | ConvertFrom-Json
Check ($emptyMove.status -eq 'manifest_missing' -and $emptyMove.moved -eq 0) '缺失清单被误报为清理成功。'
Save @()
$empty=Audit
Check ($empty.counts.unregistered_needs_review -eq 1) '空清单掩盖了漏记文件。'
$emptyMove=& $move -Root $fixture -Manifest $manifest -Apply | ConvertFrom-Json
Check ($emptyMove.status -eq 'no_candidates') '空清单未明确报告状态。'
$f=[pscustomobject]@{path='unused.txt'; sha256=(Get-FileHash -LiteralPath (Join-Path $fixture 'unused.txt')).Hash; reason='本测试明确弃用'; generatedThisTask=$false; useDecision='discard'}
Save @($f)
$a=Audit
Check ($a.counts.evidence_required -eq 1) '无授权的历史文件未拦截。'
Reject { & $move -Root $fixture -Manifest $manifest -Apply }
$f | Add-Member -NotePropertyName cleanupApproved -NotePropertyValue $true
$f | Add-Member -NotePropertyName provenance -NotePropertyValue '本脚本创建的隔离样本；用户授权修复及测试，本样本用于弃用后恢复测试。'
Save @($f)
$a=Audit
Check ($a.counts.candidate_requires_preflight -eq 1) '有依据的历史弃用文件仍被拒绝。'
$hash=$f.sha256
& $move -Root $fixture -Manifest $manifest | Out-Null
Check (Test-Path -LiteralPath (Join-Path $fixture 'unused.txt')) '预览发生了搬移。'
$r=& $move -Root $fixture -Manifest $manifest -Apply | ConvertFrom-Json
Check ($r.moved -eq 1) '历史弃用样本未被搬移。'
Check (-not (Test-Path -LiteralPath (Join-Path $fixture 'unused.txt'))) '原路径仍存在。'
$after=Audit
Check ($after.counts.not_observed -eq 1) '失效登记未被报告。'
& $move -Root $fixture -Manifest $r.receipt -Restore -Apply | Out-Null
Check ((Get-FileHash -LiteralPath (Join-Path $fixture 'unused.txt')).Hash -eq $hash) '恢复后哈希不一致。'
$f.useDecision='unconfirmed'
Save @($f)
Reject { & $move -Root $fixture -Manifest $manifest -Apply }
$f.useDecision='keep'
Save @($f)
$a=Audit
Check ($a.counts.keep -eq 1) '保留项未被识别。'
Reject { & $move -Root $fixture -Manifest $manifest -Apply }
$f.useDecision='discard'
Save @($f)
Add-Content -LiteralPath (Join-Path $fixture 'unused.txt') -Value '内容已改变'
$a=Audit
Check ($a.counts.changed -eq 1) '哈希变化未被识别。'
Reject { & $move -Root $fixture -Manifest $manifest -Apply }
New-Item -ItemType Directory -Path (Join-Path $fixture 'nested') | Out-Null
Set-Content -LiteralPath (Join-Path $fixture 'nested/deep.txt') -Value '深度边界样本'
$limited=& $inspect -Root $fixture -Manifest $manifest -MaxDepth 0 | ConvertFrom-Json
Check (-not $limited.enumerationCompleteWithinExclusions -and @($limited.gaps).Count -gt 0) '扫描深度截断被误报完整。'
$limited=& $inspect -Root $fixture -Manifest $manifest -MaxFiles 1 | ConvertFrom-Json
Check (-not $limited.enumerationCompleteWithinExclusions -and $limited.scannedFiles -eq 1) '数量截断被误报完整。'
$f.path='../outside.txt'
Save @($f)
Reject { Audit }
'{}' | Set-Content -LiteralPath $manifest
Reject { Audit }
# 恢复留存的有效候选，测试现场不留下误导性的损坏清单。
$f.path='unused.txt'; $f.sha256=(Get-FileHash -LiteralPath (Join-Path $fixture 'unused.txt')).Hash
$f.useDecision='keep'; Save @($f)
[pscustomobject]@{passed=$passed; fixtureRoot=$fixture; historicalMoveReceipt=$r.receipt; note='隔离样本已实际搬移和恢复；调查与截断测试不操作真实项目。'} | ConvertTo-Json
