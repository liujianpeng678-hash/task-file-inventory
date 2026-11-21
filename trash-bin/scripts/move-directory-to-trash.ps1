param(
    [Parameter(Mandatory=$true)][string]$Root,
    [Parameter(Mandatory=$true)][string]$Manifest,
    [switch]$Apply,
    [switch]$Restore,
    [switch]$Resume
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$taskRoot = (Resolve-Path -LiteralPath $Root).ProviderPath.TrimEnd('\')
if ($taskRoot -eq [IO.Path]::GetPathRoot($taskRoot).TrimEnd('\') -or
    $taskRoot -eq [Environment]::GetFolderPath('UserProfile')) { throw '必须指定具体任务目录。' }
$helper = Join-Path $PSScriptRoot 'directory-tree.py'
$doc = Get-Content -LiteralPath $Manifest -Raw -Encoding UTF8 | ConvertFrom-Json
if ($doc.root -ne $taskRoot) { throw '清单不属于当前根目录。' }
function In-Root([string]$path) {
    $full = [IO.Path]::GetFullPath($path)
    if (-not $full.StartsWith($taskRoot+'\',[StringComparison]::OrdinalIgnoreCase)) { throw '路径越出任务目录。' }
    $check = $full
    while ($check) {
        if (Test-Path -LiteralPath $check) {
            if ((Get-Item -LiteralPath $check -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw '路径含链接。' }
        }
        $check = [IO.Path]::GetDirectoryName($check)
    }
    return $full
}
function Read-Tree([string]$path) {
    $raw = & python -X utf8 $helper $path
    if ($LASTEXITCODE -ne 0) { throw '目录检查失败，未继续移动。' }
    return ($raw | ConvertFrom-Json)
}
function Check-Tree([string]$path, $expected) {
    $actual = Read-Tree $path
    foreach ($key in @('inode','device','tree_sha256','files','directories','logical_bytes')) {
        if ($actual.$key -ne $expected.$key) { throw "目录在预检后变化：$key；停止，保留现场。" }
    }
}
function File-SHA([string]$path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($path))).Replace('-','') }
    finally { $sha.Dispose() }
}
$moves = [Collections.Generic.List[object]]::new()
$resumed = [Collections.Generic.List[object]]::new()
$trashBase = if ($null -ne $doc.PSObject.Properties['trash_base']) { In-Root $doc.trash_base } else { In-Root (Join-Path $taskRoot '.task-trash') }
if ([IO.Path]::GetFileName($trashBase) -notin @('.task-trash','99 垃圾堆')) { throw '只允许任务垃圾堆或项目既有垃圾堆。' }
$destRoot = In-Root $doc.trash_root
if (-not $destRoot.StartsWith($trashBase+'\',[StringComparison]::OrdinalIgnoreCase)) { throw '目标不是任务可恢复区。' }
$seen = @{}
foreach ($item in $doc.directories) {
    if ($item.cleanupApproved -cne $true -or $item.useDecision -cne 'discard' -or
        [string]::IsNullOrWhiteSpace($item.provenance)) { throw '缺少本次整目录弃用授权。' }
    $original = In-Root $item.source
    $target = In-Root $item.target
    if ($original -eq $trashBase -or $original.StartsWith($trashBase+'\',[StringComparison]::OrdinalIgnoreCase) -or
        -not $target.StartsWith($destRoot+'\',[StringComparison]::OrdinalIgnoreCase)) { throw '原位置或目标区域无效。' }
    if ($seen.ContainsKey($original) -or $seen.ContainsKey($target)) { throw '重复路径。' }
    $seen[$original]=$true; $seen[$target]=$true
    foreach ($other in $moves) {
        if ($original.StartsWith($other.original+'\',[StringComparison]::OrdinalIgnoreCase) -or
            $other.original.StartsWith($original+'\',[StringComparison]::OrdinalIgnoreCase)) { throw '不允许嵌套目录重复清扫。' }
    }
    $source = if ($Restore) { $target } else { $original }
    $destination = if ($Restore) { $original } else { $target }
    if ($Resume -and -not $Restore -and -not (Test-Path -LiteralPath $source) -and (Test-Path -LiteralPath $destination)) {
        Check-Tree $destination $item.tree
        $resumed.Add([pscustomobject]@{source=$source;target=$destination;state='verified_after_resume'})
        continue
    }
    if (Test-Path -LiteralPath $destination) { throw '恢复或移动目标已存在，禁止覆盖。' }
    Check-Tree $source $item.tree
    $moves.Add([pscustomobject]@{original=$original;source=$source;target=$destination;tree=$item.tree})
}
if (-not $Apply) {
    [pscustomobject]@{status='preview_passed'; directories=$moves.Count; previously_verified=$resumed.Count; moves=$moves} | ConvertTo-Json -Depth 9
    return
}
if (-not $Restore) {
    if (-not (Test-Path -LiteralPath $destRoot)) { New-Item -ItemType Directory -Path $destRoot | Out-Null }
    $savedManifest = Join-Path $destRoot 'restore-manifest.json'
    if (Test-Path -LiteralPath $savedManifest) {
        if (-not $Resume -or (File-SHA $savedManifest) -ne (File-SHA $Manifest)) { throw '已有恢复清单，不覆盖或猜测接续。' }
    } else { Copy-Item -LiteralPath $Manifest -Destination $savedManifest }
}
$journal = Join-Path $destRoot $(if ($Restore) {'restore-receipt.jsonl'} else {'receipt.jsonl'})
foreach ($entry in $resumed) { $entry | ConvertTo-Json -Compress | Add-Content -LiteralPath $journal -Encoding UTF8 }
foreach ($move in $moves) {
    Check-Tree $move.source $move.tree
    $source = In-Root $move.source; $target = In-Root $move.target
    if (Test-Path -LiteralPath $target) { throw '目标在预检后出现，停止。' }
    if ([IO.Path]::GetPathRoot($source) -ne [IO.Path]::GetPathRoot($target)) { throw '禁止跨盘移动。' }
    $parent = [IO.Path]::GetDirectoryName($target)
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [pscustomobject]@{state='moving';source=$source;target=$target;utc=[DateTime]::UtcNow.ToString('o')} |
        ConvertTo-Json -Compress | Add-Content -LiteralPath $journal -Encoding UTF8
    Move-Item -LiteralPath $source -Destination $target
    Check-Tree $target $move.tree
    [pscustomobject]@{state='verified';source=$source;target=$target;utc=[DateTime]::UtcNow.ToString('o')} |
        ConvertTo-Json -Compress | Add-Content -LiteralPath $journal -Encoding UTF8
}
[pscustomobject]@{status='passed';moved_directories=$moves.Count;previously_verified=$resumed.Count;restored=[bool]$Restore;receipt=$journal;released_bytes=0} | ConvertTo-Json
