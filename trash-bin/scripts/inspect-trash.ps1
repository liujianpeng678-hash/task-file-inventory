param(
    [Parameter(Mandatory = $true)][string]$Root,
    [string]$Manifest,
    [ValidateRange(1, 100000)][int]$MaxFiles = 2000,
    [ValidateRange(0, 100)][int]$MaxDepth = 6
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# 仅调查指定任务目录，不写清单、不改文件、不推断未登记文件可删除。
$taskRoot = (Resolve-Path -LiteralPath $Root).ProviderPath.TrimEnd('\', '/')
if (-not (Test-Path -LiteralPath $taskRoot -PathType Container) -or
    $taskRoot -eq [IO.Path]::GetPathRoot($taskRoot).TrimEnd('\', '/') -or
    $taskRoot -eq [Environment]::GetFolderPath('UserProfile')) { throw '请指定具体任务目录，不能扫描整盘或用户根目录。' }
$ancestor = $taskRoot
while ($ancestor) {
    if ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw '扫描根路径不能经过链接或目录联接。' }
    $ancestor = [IO.Path]::GetDirectoryName($ancestor)
}
if (-not $Manifest) { $Manifest = Join-Path $taskRoot '.task-trash/candidates.json' }
$manifestPath = [IO.Path]::GetFullPath($Manifest)
$manifestState = 'missing'
$registered = @{}
if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
    $doc = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -eq $doc.PSObject.Properties['files']) { throw '候选清单缺少 files 字段，不能作为空清单处理。' }
    $manifestState = 'loaded'
    foreach ($f in @($doc.files)) {
        if ($null -eq $f -or [string]::IsNullOrWhiteSpace([string]$f.path) -or
            [IO.Path]::IsPathRooted($f.path) -or $f.path.Contains(':')) { throw '候选路径无效。' }
        $full = [IO.Path]::GetFullPath((Join-Path $taskRoot $f.path))
        if (-not $full.StartsWith($taskRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw '候选路径越出任务目录。' }
        if ($registered.ContainsKey($full)) { throw '候选清单包含重复路径。' }
        $registered[$full] = $f
    }
}
$entries = [Collections.Generic.List[object]]::new()
$gaps = [Collections.Generic.List[object]]::new()
$excluded = [Collections.Generic.List[string]]::new()
$seen = @{}
$stack = [Collections.Generic.Stack[object]]::new()
$stack.Push(@{path=$taskRoot; depth=0})
$count = 0
$limitReached = $false
while ($stack.Count -gt 0 -and -not $limitReached) {
    $dir = $stack.Pop()
    try { $children = @(Get-ChildItem -LiteralPath $dir.path -Force -ErrorAction Stop | Sort-Object Name) }
    catch { $gaps.Add(@{path=$dir.path; reason='无法读取目录'; detail=$_.Exception.Message}); continue }
    foreach ($item in $children) {
        $relative = $item.FullName.Substring($taskRoot.Length + 1)
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            $gaps.Add(@{path=$relative; reason='链接或目录联接，未跟随'}); continue
        }
        if ($item.PSIsContainer) {
            if ($item.Name -in @('.git', '.task-trash', '.codex', '.agents', 'node_modules', '.venv')) {
                $excluded.Add($relative); continue
            }
            if ($dir.depth -ge $MaxDepth) { $gaps.Add(@{path=$relative; reason='达到扫描深度上限'}); continue }
            $stack.Push(@{path=$item.FullName; depth=($dir.depth + 1)})
            continue
        }
        if ($count -ge $MaxFiles) { $limitReached = $true; $gaps.Add(@{path=$relative; reason='达到文件数量上限，余项未扫描'}); break }
        $count++
        $seen[$item.FullName] = $true
        $state = 'unregistered_needs_review'
        $reason = '未登记；名称、时间和大小不能证明已弃用。'
        if ($item.FullName -eq $manifestPath -or $relative -match '(^|[\\/])(\.env(?:\..*)?|AGENTS(?:\.override)?\.md)$') {
            $state = 'protected'; $reason = '清单或受保护配置文件。'
        } elseif ($registered.ContainsKey($item.FullName)) {
            $f = $registered[$item.FullName]
            $decision = $f.PSObject.Properties['useDecision']
            $legacy = $f.PSObject.Properties['unusedConfirmed']
            $generated = $f.PSObject.Properties['generatedThisTask']
            $approved = $f.PSObject.Properties['cleanupApproved']
            $provenance = $f.PSObject.Properties['provenance']
            $why = $f.PSObject.Properties['reason']
            $hash = $f.PSObject.Properties['sha256']
            $eligible = ($null -ne $decision -and $decision.Value -cin @('discard','unconfirmed')) -or
                ($null -eq $decision -and $null -ne $legacy -and $legacy.Value -ceq $true)
            $sourceOK = ($null -ne $generated -and $generated.Value -ceq $true) -or
                ($null -ne $decision -and $decision.Value -ceq 'discard' -and $null -ne $approved -and $approved.Value -ceq $true -and
                $null -ne $provenance -and -not [string]::IsNullOrWhiteSpace([string]$provenance.Value))
            if ($null -ne $decision -and $decision.Value -ceq 'keep') {
                $state='keep'; $reason='已确认保留。'
            } elseif (-not $eligible -or -not $sourceOK -or $null -eq $why -or [string]::IsNullOrWhiteSpace([string]$why.Value)) {
                $state='evidence_required'; $reason='用途、来源或本次清扫范围依据不足。'
            } elseif ($null -eq $hash -or $hash.Value -notmatch '^[a-fA-F0-9]{64}$') {
                $state='invalid_hash'; $reason='缺少有效 SHA-256。'
            } else {
                try {
                    if ((Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash -ne $hash.Value) {
                        $state='changed'; $reason='文件内容已变，原登记不能直接执行。'
                    } else { $state='candidate_requires_preflight'; $reason='登记与哈希有效；仍须搬移脚本检查 Git 保护等执行条件。' }
                } catch { $state='unreadable'; $reason=$_.Exception.Message }
            }
        }
        $entries.Add([pscustomobject]@{path=$relative; bytes=$item.Length; state=$state; reason=$reason})
    }
}
foreach ($full in $registered.Keys) {
    if (-not $seen.ContainsKey($full)) {
        # 未扫描到的路径不访问，避免越过深度、目录联接或排除边界。
        $entries.Add([pscustomobject]@{path=$registered[$full].path; bytes=$null; state='not_observed'; reason='本次扫描未见：可能已搬走、不存在或位于未检查范围；须另查回执与精确路径。'})
    }
}
$counts = [ordered]@{}
foreach ($entry in $entries) {
    if (-not $counts.Contains($entry.state)) { $counts[$entry.state] = 0 }
    $counts[$entry.state]++
}
[pscustomobject]@{
    status='inspection_only'; root=$taskRoot; manifest=$manifestPath; manifestState=$manifestState
    scannedFiles=$count; enumerationCompleteWithinExclusions=($gaps.Count -eq 0)
    limits=@{maxFiles=$MaxFiles; maxDepth=$MaxDepth}; excludedDirectories=@($excluded.ToArray())
    gaps=@($gaps.ToArray()); counts=$counts; entries=@($entries.ToArray())
    conclusion='这是有边界的只读调查。零候选不等于没有垃圾；未登记项需核对用途和依赖，未检查范围必须如实报告。'
} | ConvertTo-Json -Depth 8
