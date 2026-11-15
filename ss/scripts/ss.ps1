#requires -Version 7.0
<#
skill-hub engine — one local source of truth, junctioned into every agent's skill root.

Commands:
  scan      read-only inventory of every skill root (real dirs, junctions, dangling links)
  doctor    read-only health report (duplicates, dangling links, unmanaged copies, bad frontmatter)
  list      hub contents + which agents each skill is linked into
  link      create junctions from hub skills into every existing agent root
  unlink    remove junctions that point into the hub
  add       download a skill from GitHub into the hub (SHA-verified) and record it in skills.json
  migrate   move real agent copies into the hub and replace them with junctions (dry-run by default)
#>

param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('scan', 'doctor', 'list', 'link', 'unlink', 'add', 'migrate')]
    [string]$Command,

    [string]$Repo,
    [string]$Skill,
    [string]$SkillPath,
    [string]$Ref = 'main',
    [string]$Agent,
    [string]$Config,
    [string]$Token = $env:GITHUB_TOKEN,
    [switch]$Apply,
    [switch]$DryRun,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$Separator = ('-' * 78)

# ---------------------------------------------------------------- config ----

function Expand-PathTemplate([string]$raw) {
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    $s = $raw.Trim()
    if ($s.StartsWith('~')) { $s = $env:USERPROFILE + $s.Substring(1) }
    return [Environment]::ExpandEnvironmentVariables($s)
}

function Get-Config {
    param([string]$explicit)
    $candidates = @()
    if ($explicit) { $candidates += $explicit }
    $candidates += (Join-Path $PSScriptRoot '..\agents.json')
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) {
            $cfg = Get-Content -LiteralPath $c -Raw -Encoding utf8 | ConvertFrom-Json
            return $cfg
        }
    }
    throw "agents.json not found (looked in: $($candidates -join ', '))"
}

$cfg = Get-Config $Config
$hub = Expand-PathTemplate $cfg.hub
$selfName = if ($cfg.self_skill) { $cfg.self_skill } else { 'skill-hub' }
$readonly = @($cfg.readonly_agents)
$disabled = @($cfg.disabled_agents)
$agentMap = [ordered]@{}
foreach ($p in $cfg.agents.PSObject.Properties) {
    $agentMap[$p.Name] = Expand-PathTemplate $p.Value
}
$manifestPath = Join-Path $hub 'skills.json'

# --------------------------------------------------------------- helpers ----

function Get-EntryKind($item) {
    if ($item.LinkType -eq 'Junction' -or $item.LinkType -eq 'SymbolicLink') {
        $target = @($item.Target)[0]
        if ($target -and (Test-Path -LiteralPath $target)) { return 'link' }
        return 'dangling'
    }
    if ($item.PSIsContainer) { return 'real' }
    return 'file'
}

function Get-Frontmatter($skillDir) {
    $md = Join-Path $skillDir 'SKILL.md'
    if (-not (Test-Path -LiteralPath $md)) { return $null }
    $lines = Get-Content -LiteralPath $md -TotalCount 30 -Encoding utf8
    $name = $null; $desc = $null
    foreach ($l in $lines) {
        if (-not $name -and $l -match '^\s*name:\s*(.+)$') { $name = $Matches[1].Trim().Trim('"', "'") }
        if (-not $desc -and $l -match '^\s*description:\s*(.+)$') { $desc = $Matches[1].Trim().Trim('"', "'") }
    }
    return [pscustomobject]@{ Name = $name; Description = $desc; HasSkillMd = $true }
}

function Get-DirStats($dir) {
    $files = @(Get-ChildItem -LiteralPath $dir -Recurse -File -ErrorAction SilentlyContinue)
    $bytes = ($files | Measure-Object Length -Sum).Sum
    if (-not $bytes) { $bytes = 0 }
    return [pscustomobject]@{ Files = $files.Count; Bytes = [int64]$bytes }
}

function Get-SkillSignature($dir) {
    $rows = New-Object System.Collections.Generic.List[string]
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Recurse -File -ErrorAction SilentlyContinue)) {
        $rel = $f.FullName.Substring($dir.Length).TrimStart('\')
        $hash = $null
        if ($f.Extension -eq '.md') {
            $text = [IO.File]::ReadAllText($f.FullName)
            $text = $text.TrimStart([char]0xFEFF) -replace "`r`n", "`n"
            $hash = [BitConverter]::ToString(
                [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($text))
            ).Replace('-', '').ToLower()
        } else {
            $hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLower()
        }
        $rows.Add("$rel=$hash")
    }
    return ($rows | Sort-Object) -join "`n"
}

function Get-Manifest {
    if (Test-Path -LiteralPath $manifestPath) {
        return Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json
    }
    return [pscustomobject]@{ version = 1; updated_at = $null; skills = [pscustomobject]@{} }
}

function Save-Manifest($m) {
    $m.updated_at = (Get-Date).ToString('s')
    $json = $m | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($manifestPath, $json, (New-Object Text.UTF8Encoding $false))
}

function Get-HubSkills {
    if (-not (Test-Path -LiteralPath $hub)) { return @() }
    return @(Get-ChildItem -LiteralPath $hub -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin @('_rollback', '.git') })
}

function Format-KB([int64]$bytes) { return ('{0:N1} KB' -f ($bytes / 1KB)) }

function Get-AgentRoots([switch]$existingOnly) {
    $rows = @()
    foreach ($k in $agentMap.Keys) {
        if ($disabled -contains $k) { continue }
        $p = $agentMap[$k]
        $exists = Test-Path -LiteralPath $p
        if ($existingOnly -and -not $exists) { continue }
        $rows += [pscustomobject]@{ Agent = $k; Path = $p; Exists = $exists; ReadOnly = ($readonly -contains $k) }
    }
    return $rows
}

# ---------------------------------------------------------------- verbs -----

function Invoke-Scan {
    Write-Output "HUB  $hub  (exists: $(Test-Path -LiteralPath $hub))"
    Write-Output $Separator
    $roots = @([pscustomobject]@{ Agent = '(hub)'; Path = $hub; Exists = (Test-Path -LiteralPath $hub); ReadOnly = $false }) + @(Get-AgentRoots)
    foreach ($r in $roots) {
        Write-Output ""
        Write-Output ("[{0}] {1}  {2}" -f $r.Agent, $r.Path, $(if ($r.Exists) { '' } else { '(missing, skipped)' }))
        if (-not $r.Exists) { continue }
        $entries = @(Get-ChildItem -LiteralPath $r.Path -Directory -Force -ErrorAction SilentlyContinue)
        if ($entries.Count -eq 0) { Write-Output '    (empty)'; continue }
        foreach ($e in ($entries | Sort-Object Name)) {
            $kind = Get-EntryKind $e
            $stats = if ($kind -eq 'dangling') { [pscustomobject]@{ Files = 0; Bytes = 0 } } else { Get-DirStats $e.FullName }
            $fm = if ($kind -eq 'real' -or $kind -eq 'link') { Get-Frontmatter $e.FullName } else { $null }
            $badge = switch ($kind) { 'link' { 'LINK'; break } 'dangling' { 'DANGLING'; break } default { 'real' } }
            $target = if ($e.LinkType) { ' -> ' + (@($e.Target)[0]) } else { '' }
            $fmt = if ($fm -and $fm.HasSkillMd) { 'ok' } elseif ($kind -eq 'dangling') { '-' } else { 'NO SKILL.md' }
            Write-Output ("    {0,-7} {1,-26} {2,4}f {3,10}  frontmatter:{4}{5}" -f $badge, $e.Name, $stats.Files, (Format-KB $stats.Bytes), $fmt, $target)
        }
    }
}

function Invoke-Doctor {
    $issues = New-Object System.Collections.Generic.List[object]
    $hubSkills = Get-HubSkills
    $hubNames = @($hubSkills | ForEach-Object Name)

    # 1. dangling links anywhere
    foreach ($r in (Get-AgentRoots)) {
        if (-not $r.Exists) { continue }
        foreach ($e in @(Get-ChildItem -LiteralPath $r.Path -Directory -Force -ErrorAction SilentlyContinue)) {
            if ((Get-EntryKind $e) -eq 'dangling') {
                $issues.Add([pscustomobject]@{ Sev = 'ERROR'; Code = 'dangling-link'; Where = "$($r.Agent):$($e.Name)"; Detail = 'junction points at a missing target' })
            }
        }
    }

    # 2. unmanaged real copies that duplicate a hub skill / each other
    $seen = @{}
    foreach ($r in (Get-AgentRoots)) {
        if (-not $r.Exists) { continue }
        foreach ($e in @(Get-ChildItem -LiteralPath $r.Path -Directory -Force -ErrorAction SilentlyContinue)) {
            if ((Get-EntryKind $e) -ne 'real') { continue }
            if ($readonly -contains $r.Agent) { continue }
            if ($e.Name -in @($selfName, '.system')) { continue }
            if (-not (Test-Path -LiteralPath (Join-Path $e.FullName 'SKILL.md'))) {
                $issues.Add([pscustomobject]@{ Sev = 'WARN'; Code = 'no-skill-md'; Where = "$($r.Agent):$($e.Name)"; Detail = 'directory has no SKILL.md' })
            }
            if ($hubNames -contains $e.Name) {
                $sigHub = Get-SkillSignature (Join-Path $hub $e.Name)
                $sigThis = Get-SkillSignature $e.FullName
                if ($sigHub -eq $sigThis) {
                    $issues.Add([pscustomobject]@{ Sev = 'WARN'; Code = 'unmanaged-duplicate'; Where = "$($r.Agent):$($e.Name)"; Detail = 'byte-equivalent real copy of a hub skill; run migrate to replace it with a link' })
                } else {
                    $issues.Add([pscustomobject]@{ Sev = 'INFO'; Code = 'divergent-variant'; Where = "$($r.Agent):$($e.Name)"; Detail = 'same name, different content (deliberate variant); left as a real copy' })
                }
            } elseif ($seen.ContainsKey($e.Name)) {
                $issues.Add([pscustomobject]@{ Sev = 'WARN'; Code = 'duplicate-copy'; Where = "$($r.Agent):$($e.Name)"; Detail = "same name also real in $($seen[$e.Name])" })
            } else {
                $seen[$e.Name] = $r.Agent
            }
        }
    }

    # 3. hub skills linked nowhere
    foreach ($s in $hubSkills) {
        $linkedIn = @()
        foreach ($r in (Get-AgentRoots)) {
            if (-not $r.Exists) { continue }
            $p = Join-Path $r.Path $s.Name
            if ((Test-Path -LiteralPath $p) -and ((Get-Item -LiteralPath $p).LinkType)) { $linkedIn += $r.Agent }
        }
        if ($linkedIn.Count -eq 0) {
            $issues.Add([pscustomobject]@{ Sev = 'INFO'; Code = 'not-linked'; Where = "hub:$($s.Name)"; Detail = 'no agent links to this skill yet; run link' })
        }
    }

    # 4. frontmatter sanity inside hub
    foreach ($s in $hubSkills) {
        $fm = Get-Frontmatter $s.FullName
        if (-not $fm -or -not $fm.HasSkillMd) {
            $issues.Add([pscustomobject]@{ Sev = 'ERROR'; Code = 'missing-skill-md'; Where = "hub:$($s.Name)"; Detail = 'SKILL.md missing' })
        } elseif (-not $fm.Name -or -not $fm.Description) {
            $issues.Add([pscustomobject]@{ Sev = 'WARN'; Code = 'frontmatter'; Where = "hub:$($s.Name)"; Detail = 'name or description missing in frontmatter' })
        } elseif ($fm.Name -ne $s.Name) {
            $issues.Add([pscustomobject]@{ Sev = 'INFO'; Code = 'name-mismatch'; Where = "hub:$($s.Name)"; Detail = "frontmatter name is '$($fm.Name)'" })
        }
    }

    # 5. manifest drift
    $m = Get-Manifest
    foreach ($s in $hubSkills) {
        if (-not $m.skills.PSObject.Properties.Name.Contains($s.Name)) {
            $issues.Add([pscustomobject]@{ Sev = 'INFO'; Code = 'no-manifest-entry'; Where = "hub:$($s.Name)"; Detail = 'origin unknown; add an entry to skills.json' })
        }
    }

    if ($issues.Count -eq 0) { Write-Output 'OK — no issues found.'; return }
    $order = @{ ERROR = 0; WARN = 1; INFO = 2 }
    $sorted = $issues | Sort-Object { $order[$_.Sev] }, Code
    Write-Output ("{0,-6} {1,-20} {2,-32} {3}" -f 'SEV', 'CODE', 'WHERE', 'DETAIL')
    Write-Output $Separator
    foreach ($i in $sorted) {
        Write-Output ("{0,-6} {1,-20} {2,-32} {3}" -f $i.Sev, $i.Code, $i.Where, $i.Detail)
    }
    $counts = $sorted | Group-Object Sev | ForEach-Object { "$($_.Name)=$($_.Count)" }
    Write-Output ""
    Write-Output ("total {0}  ({1})" -f $sorted.Count, ($counts -join ', '))
}

function Invoke-List {
    $hubSkills = Get-HubSkills
    if (-not $hubSkills) { Write-Output "hub empty: $hub"; return }
    $roots = @(Get-AgentRoots -existingOnly)
    $header = @('SKILL') + @($roots | ForEach-Object { $_.Agent })
    Write-Output ($header -join "`t")
    Write-Output $Separator
    foreach ($s in ($hubSkills | Sort-Object Name)) {
        $cells = @($s.Name)
        foreach ($r in $roots) {
            $p = Join-Path $r.Path $s.Name
            $state = if (-not (Test-Path -LiteralPath $p)) { '-' } elseif ((Get-Item -LiteralPath $p).LinkType) { 'link' } else { '!real' }
            $cells += $state
        }
        Write-Output ($cells -join "`t")
    }
    Write-Output ""
    Write-Output 'link = junctioned, !real = an independent copy sits there, - = absent'
}

function Invoke-Link {
    param([switch]$DryRun, [string]$AgentFilter)
    if (-not (Test-Path -LiteralPath $hub)) { throw "hub missing: $hub" }
    $created = 0; $skipped = 0; $conflicts = @()
    foreach ($s in (Get-HubSkills)) {
        foreach ($r in (Get-AgentRoots)) {
            if (-not $r.Exists) { continue }
            if ($AgentFilter -and $r.Agent -ne $AgentFilter) { continue }
            if ($readonly -contains $r.Agent) { continue }
            $p = Join-Path $r.Path $s.Name
            if (Test-Path -LiteralPath $p) {
                $item = Get-Item -LiteralPath $p -Force
                if ($item.LinkType) {
                    $t = @($item.Target)[0]
                    if ($t -eq $s.FullName) { $skipped++; continue }
                    $conflicts += "$($r.Agent):$($s.Name) -> other target $t"
                    continue
                }
                $conflicts += "$($r.Agent):$($s.Name) is a real directory"
                continue
            }
            if ($DryRun) {
                Write-Output "would link  $($r.Agent):$($s.Name) -> $($s.FullName)"
                $created++
                continue
            }
            New-Item -ItemType Junction -Path $p -Target $s.FullName -ErrorAction Stop | Out-Null
            Write-Output "linked      $($r.Agent):$($s.Name)"
            $created++
        }
    }
    Write-Output ""
    Write-Output ("created={0} already-linked={1} conflicts={2}{3}" -f $created, $skipped, $conflicts.Count, $(if ($DryRun) { ' (dry run)' } else { '' }))
    foreach ($c in $conflicts) { Write-Output "  CONFLICT  $c" }
}

function Invoke-Unlink {
    param([switch]$DryRun)
    $removed = 0
    foreach ($r in (Get-AgentRoots)) {
        if (-not $r.Exists) { continue }
        foreach ($e in @(Get-ChildItem -LiteralPath $r.Path -Directory -Force -ErrorAction SilentlyContinue)) {
            if (-not $e.LinkType) { continue }
            $t = @($e.Target)[0]
            if (-not $t) { continue }
            if (-not $t.StartsWith($hub, 'OrdinalIgnoreCase')) { continue }
            if ($DryRun) { Write-Output "would unlink $($r.Agent):$($e.Name)"; $removed++; continue }
            $e.Delete()
            Write-Output "unlinked     $($r.Agent):$($e.Name)"
            $removed++
        }
    }
    Write-Output ("removed={0}{1}" -f $removed, $(if ($DryRun) { ' (dry run)' } else { '' }))
}

# --------------------------------------------------------------- network ----

function Invoke-GitHubJson([string]$url) {
    $headers = @{ 'User-Agent' = 'skill-hub'; Accept = 'application/vnd.github+json' }
    if ($Token) { $headers['Authorization'] = "Bearer $Token" }
    for ($i = 0; $i -lt 3; $i++) {
        try {
            return Invoke-RestMethod -Uri $url -Headers $headers -TimeoutSec 60
        } catch {
            if ($i -eq 2) { throw }
            Start-Sleep -Seconds (2 * ($i + 1))
        }
    }
}

function Invoke-GitHubRaw([string]$url) {
    $headers = @{ 'User-Agent' = 'skill-hub' }
    if ($Token) { $headers['Authorization'] = "Bearer $Token" }
    # .Content comes back as a decoded string; download to disk so the bytes stay exact
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("skh-" + [guid]::NewGuid().ToString('N') + ".bin")
    try {
        Invoke-WebRequest -Uri $url -Headers $headers -TimeoutSec 120 -OutFile $tmp
        return [IO.File]::ReadAllBytes($tmp)
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Get-GitBlobSha([byte[]]$bytes) {
    $h = [Security.Cryptography.SHA1]::Create()
    $prefix = [Text.Encoding]::ASCII.GetBytes("blob $($bytes.Length)`0")
    $h.TransformBlock($prefix, 0, $prefix.Length, $null, 0) | Out-Null
    $h.TransformFinalBlock($bytes, 0, $bytes.Length) | Out-Null
    return ([BitConverter]::ToString($h.Hash)).Replace('-', '').ToLower()
}

function Invoke-Add {
    if (-not $Repo) { throw 'add requires -Repo owner/repo' }
    if (-not $Skill) { throw 'add requires -Skill name' }
    if (-not (Test-Path -LiteralPath $hub)) { New-Item -ItemType Directory -Path $hub -Force | Out-Null }

    $tree = Invoke-GitHubJson "https://api.github.com/repos/$Repo/git/trees/$Ref`?recursive=1"
    if ($tree.truncated) { throw "tree for $Repo is truncated; pass -SkillPath to scope the download manually" }
    $blobs = @($tree.tree | Where-Object { $_.type -eq 'blob' })
    $prefix = $SkillPath
    if (-not $prefix) {
        $candidates = $blobs | Where-Object { $_.path -eq "$Skill/SKILL.md" -or $_.path -like "*/$Skill/SKILL.md" }
        if ($candidates.Count -eq 0) { throw "no SKILL.md found for skill '$Skill' in $Repo@$Ref" }
        if ($candidates.Count -gt 1) { throw "ambiguous: $($candidates.path -join ', '); pass -SkillPath" }
        $prefix = $candidates[0].path.Substring(0, $candidates[0].path.Length - '/SKILL.md'.Length)
    }
    $files = @($blobs | Where-Object { $_.path.StartsWith("$prefix/") })
    if ($files.Count -eq 0) { throw "no files under $prefix" }

    $dest = Join-Path $hub $Skill
    if ((Test-Path -LiteralPath $dest) -and -not $Force) { throw "$dest already exists; pass -Force to overwrite" }
    $verified = 0; $failed = @()
    foreach ($f in $files) {
        $rel = $f.path.Substring($prefix.Length + 1)
        $rawUrl = "https://raw.githubusercontent.com/$Repo/$Ref/$($f.path)"
        try {
            $bytes = Invoke-GitHubRaw $rawUrl
        } catch {
            $failed += "$rel (download)"
            continue
        }
        if ((Get-GitBlobSha $bytes) -ne $f.sha) { $failed += "$rel (sha mismatch)"; continue }
        $out = Join-Path $dest $rel
        New-Item -ItemType Directory -Path (Split-Path -Parent $out) -Force | Out-Null
        [IO.File]::WriteAllBytes($out, $bytes)
        $verified++
    }
    if ($failed.Count) { Write-Output ("FAILED files: {0}" -f ($failed -join '; ')); throw "add aborted: $($failed.Count) file(s) failed verification" }

    $m = Get-Manifest
    $entry = [pscustomobject]@{
        origin       = 'github'
        repo         = $Repo
        path         = $prefix
        ref          = $Ref
        installed_at = (Get-Date).ToString('s')
        files        = $verified
    }
    $m.skills | Add-Member -NotePropertyName $Skill -NotePropertyValue $entry -Force
    Save-Manifest $m
    Write-Output "added $Skill from $Repo@$Ref ($verified files, all SHA-verified) -> $dest"
}

# --------------------------------------------------------------- migrate ----

function Invoke-Migrate {
    param([switch]$DryRun)
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $rollbackDir = Join-Path $hub '_rollback'
    if (-not $DryRun -and -not (Test-Path -LiteralPath $rollbackDir)) { New-Item -ItemType Directory -Path $rollbackDir -Force | Out-Null }
    $rollback = New-Object System.Collections.Generic.List[string]
    $rollback.Add('# skill-hub rollback, generated ' + (Get-Date).ToString('s'))
    $rollback.Add('# 拆掉本次新建的链接，把目录移回原处')
    $rbPath = Join-Path $rollbackDir "migrate-$stamp.ps1"
    function Write-RollbackFile {
        if ($DryRun) { return }
        [IO.File]::WriteAllText($rbPath, ($rollback -join "`r`n") + "`r`n", (New-Object Text.UTF8Encoding $true))
    }
    Write-RollbackFile

    if (-not (Test-Path -LiteralPath $hub)) { New-Item -ItemType Directory -Path $hub -Force | Out-Null }

    $moved = 0; $dedup = 0; $conflicts = @()
    $hubSkills = Get-HubSkills
    foreach ($r in (Get-AgentRoots)) {
        if (-not $r.Exists) { continue }
        if ($readonly -contains $r.Agent) { continue }
        foreach ($e in @(Get-ChildItem -LiteralPath $r.Path -Directory -Force -ErrorAction SilentlyContinue)) {
            if (-not $e.LinkType -and $e.Name -in @($selfName, '.system')) { continue }
            if ($e.LinkType) { continue }
            if ($e.Name -eq $selfName) { continue }
            $src = $e.FullName
            $devNull = $null
            $dest = Join-Path $hub $e.Name
            if (Test-Path -LiteralPath $dest) {
                # same name already in hub: compare signatures, delete the duplicate if equivalent
                $sigA = Get-SkillSignature $dest
                $sigB = Get-SkillSignature $src
                if ($sigA -eq $sigB) {
                    if ($DryRun) { Write-Output "would dedup $($r.Agent):$($e.Name) (identical to hub copy)"; $dedup++ ; continue }
                    Remove-Item -LiteralPath $src -Recurse -Force
                    New-Item -ItemType Junction -Path $src -Target $dest | Out-Null
                    $rollback.Add("Remove-Item -LiteralPath '$src' -Force")
                    $rollback.Add("Copy-Item -LiteralPath '$dest' -Destination '$src' -Recurse -Force")
                    Write-RollbackFile
                    Write-Output "deduped     $($r.Agent):$($e.Name) (byte-equivalent, now junction)"
                    $dedup++
                    continue
                }
                $conflicts += "$($r.Agent):$($e.Name) differs from hub copy (content mismatch), left untouched"
                continue
            }
            if ($DryRun) { Write-Output "would move  $src -> $dest  then junction back"; $moved++; continue }
            Move-Item -LiteralPath $src -Destination $dest
            New-Item -ItemType Junction -Path $src -Target $dest | Out-Null
            $rollback.Add("Remove-Item -LiteralPath '$src' -Force")
            $rollback.Add("Move-Item -LiteralPath '$dest' -Destination '$src'")
            Write-RollbackFile
            Write-Output "moved+linked $($r.Agent):$($e.Name)"
            $moved++
        }
    }

    if (-not $DryRun) {
        Write-RollbackFile
        Write-Output ""
        Write-Output "rollback script: $rbPath"
    }
    Write-Output ("moved={0} deduped={1} conflicts={2}{3}" -f $moved, $dedup, $conflicts.Count, $(if ($DryRun) { ' (dry run)' } else { '' }))
    foreach ($c in $conflicts) { Write-Output "  CONFLICT  $c" }
}

# ------------------------------------------------------------------ run -----

switch ($Command) {
    'scan' { Invoke-Scan }
    'doctor' { Invoke-Doctor }
    'list' { Invoke-List }
    'link' { Invoke-Link -DryRun:$DryRun -AgentFilter $Agent }
    'unlink' { Invoke-Unlink -DryRun:$DryRun }
    'add' { Invoke-Add }
    'migrate' {
        if (-not $Apply) { Invoke-Migrate -DryRun }
        else { Invoke-Migrate }
    }
}
