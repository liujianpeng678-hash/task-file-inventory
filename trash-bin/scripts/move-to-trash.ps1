param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Manifest,
    [switch]$Apply,
    [switch]$Restore
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-NoLink([string]$Path) {
    $fullPath = [IO.Path]::GetFullPath($Path)
    $check = $fullPath
    while ($check) {
        if (Test-Path -LiteralPath $check) {
            $item = Get-Item -LiteralPath $check -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Links and junctions are not allowed.' }
            if ($check -ne $fullPath -and -not $item.PSIsContainer) { throw 'An existing parent path is a file, not a directory.' }
        }
        $check = [IO.Path]::GetDirectoryName($check)
    }
}
function Resolve-InRoot([string]$Relative) {
    if ([string]::IsNullOrWhiteSpace($Relative) -or [IO.Path]::IsPathRooted($Relative) -or $Relative.Contains(':')) {
        throw 'Expected a relative file path without stream syntax.'
    }
    $full = [IO.Path]::GetFullPath((Join-Path $taskRoot $Relative))
    if (-not $full.StartsWith($taskRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'File path escapes the task root.'
    }
    Assert-NoLink $full
    return $full
}
function Assert-Hash([string]$Path, [string]$Hash) {
    if ($Hash -notmatch '^[a-fA-F0-9]{64}$' -or (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $Hash) {
        throw 'File contents changed or hash is invalid; no further files will move.'
    }
}

$taskRoot = (Resolve-Path -LiteralPath $Root).ProviderPath.TrimEnd('\', '/')
if (-not (Test-Path -LiteralPath $taskRoot -PathType Container) -or
    $taskRoot -eq [IO.Path]::GetPathRoot($taskRoot).TrimEnd('\', '/') -or
    $taskRoot -eq [Environment]::GetFolderPath('UserProfile') -or
    $taskRoot -eq [IO.Path]::GetTempPath().TrimEnd('\', '/')) { throw 'Choose a specific task directory.' }
Assert-NoLink $taskRoot
if (-not (Test-Path -LiteralPath $Manifest -PathType Leaf)) {
    if ($Restore) { throw '恢复清单不存在。' }
    [pscustomobject]@{status='manifest_missing'; moved=0; message='候选清单不存在，尚未检查是否有遗漏；请先运行 inspect-trash.ps1。不能据此认定没有垃圾。'} | ConvertTo-Json
    return
}
$manifestPath = (Resolve-Path -LiteralPath $Manifest).ProviderPath
Assert-NoLink $manifestPath
$document = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$files = @($document.files)
if ($files.Count -eq 0) {
    [pscustomobject]@{status='no_candidates'; moved=0; message='清单没有候选，不代表没有垃圾；清扫前须在指定任务目录检查漏记。'} | ConvertTo-Json
    return
}
$trashRoot = Join-Path $taskRoot '.task-trash'
Assert-NoLink $trashRoot
if ($Restore) {
    if ($document.root -ne $taskRoot -or [IO.Path]::GetFileName($manifestPath) -ne 'receipt.json' -or
        -not $manifestPath.StartsWith($trashRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Receipt must belong to this task root and its trash directory.'
    }
    $batchRoot = [IO.Path]::GetDirectoryName($manifestPath)
} else {
    $batchRoot = Join-Path $trashRoot ([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N'))
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'Git is required to check tracked-file protection.' }
}
$seen = @{}
$moves = @()
foreach ($file in $files) {
    $decisionProperty = $file.PSObject.Properties['useDecision']
    $legacyProperty = $file.PSObject.Properties['unusedConfirmed']
    if ($null -ne $decisionProperty) {
        $eligible = $decisionProperty.Value -cin @('discard', 'unconfirmed')
    } else {
        $eligible = $null -ne $legacyProperty -and $legacyProperty.Value -ceq $true
    }
    $historyApproval = $file.PSObject.Properties['cleanupApproved']
    $historyEvidence = $file.PSObject.Properties['provenance']
    $historyAllowed = $null -ne $decisionProperty -and $decisionProperty.Value -ceq 'discard' -and
        $null -ne $historyApproval -and $historyApproval.Value -ceq $true -and
        $null -ne $historyEvidence -and -not [string]::IsNullOrWhiteSpace([string]$historyEvidence.Value)
    if (($file.generatedThisTask -cne $true -and -not $historyAllowed) -or -not $eligible -or
        [string]::IsNullOrWhiteSpace($file.reason)) { throw '缺少来源或用途依据；历史文件需明确弃用、provenance 和本次清扫 cleanupApproved=true。' }
    $original = Resolve-InRoot $file.path
    $relative = $original.Substring($taskRoot.Length + 1)
    if ($relative -match '(^|[\\/])(\.git|\.codex|\.agents|\.task-trash|\.env(?:\..*)?)([\\/]|$)' -or
        $relative -match '(^|[\\/])AGENTS(?:\.override)?\.md$') { throw 'Protected path cannot be cleaned.' }
    if ($original -eq $manifestPath -or $seen.ContainsKey($original)) { throw 'Duplicate or self-referencing candidate.' }
    $seen[$original] = $true
    $trashed = [IO.Path]::GetFullPath((Join-Path $batchRoot ('files\' + $relative)))
    Assert-NoLink $trashed
    if ($Restore) { $source = $trashed; $target = $original } else { $source = $original; $target = $trashed }
    if ($Restore -and -not (Test-Path -LiteralPath $source) -and (Test-Path -LiteralPath $target -PathType Leaf)) {
        Assert-Hash $target $file.sha256
        continue
    }
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw 'Selected source is not an existing regular file.' }
    if (Test-Path -LiteralPath $target) { throw 'Destination already exists; overwriting is forbidden.' }
    Assert-Hash $source $file.sha256
    if (-not $Restore) {
        # 先逐级检查真实路径中的Git元数据；非仓库不为每个文件启动一次Git进程。
        # 不缓存阴性结果，避免遗漏同一批次中新增的嵌套仓库或工作树.git文件。
        $gitParent = [IO.Path]::GetDirectoryName($original)
        $hasGitMetadata = -not [string]::IsNullOrWhiteSpace($env:GIT_DIR) -or -not [string]::IsNullOrWhiteSpace($env:GIT_WORK_TREE)
        while ($gitParent -and -not $hasGitMetadata) {
            if (Test-Path -LiteralPath (Join-Path $gitParent '.git')) { $hasGitMetadata = $true; break }
            $gitParent = [IO.Path]::GetDirectoryName($gitParent)
        }
        if ($hasGitMetadata) {
            $savedPreference = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try { & git --literal-pathspecs -C ([IO.Path]::GetDirectoryName($original)) ls-files --error-unmatch -- ([IO.Path]::GetFileName($original)) *> $null; $gitExit = $LASTEXITCODE }
            finally { $ErrorActionPreference = $savedPreference }
            if ($gitExit -eq 0) { throw 'Git-tracked files are protected.' }
            if ($gitExit -eq 128) { throw 'Git protection check failed inside a repository.' }
            if ($gitExit -ne 1) { throw 'Git protection check failed.' }
        }
    }
    $moves += [pscustomobject]@{source=$source; target=$target; hash=$file.sha256; bytes=(Get-Item -LiteralPath $source).Length}
}
if (-not $Apply) {
    $moves | Select-Object source, target | ConvertTo-Json -Depth 4
    return
}
if ($moves.Count -eq 0) {
    [pscustomobject]@{status='no_remaining_moves'; moved=0; message='本清单没有剩余操作；不代表任务目录没有其他待检查文件。'} | ConvertTo-Json
    return
}
if (-not $Restore) {
    New-Item -ItemType Directory -Path $batchRoot | Out-Null
    [ordered]@{root=$taskRoot; files=$files; createdUtc=[DateTime]::UtcNow.ToString('o')} |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $batchRoot 'receipt.json') -Encoding UTF8
}
foreach ($move in $moves) {
    Assert-NoLink $move.source
    Assert-NoLink $move.target
    Assert-Hash $move.source $move.hash
    if (Test-Path -LiteralPath $move.target) { throw 'Destination appeared after preview.' }
    $parent = [IO.Path]::GetDirectoryName($move.target)
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent | Out-Null }
    Move-Item -LiteralPath $move.source -Destination $move.target
}
[pscustomobject]@{moved=$moves.Count; bytes=($moves | Measure-Object -Property bytes -Sum).Sum; restored=[bool]$Restore; receipt=(Join-Path $batchRoot 'receipt.json')} | ConvertTo-Json
