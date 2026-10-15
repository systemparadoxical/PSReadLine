# SyncBuildPSReadLine.ps1
#
# Run from a fork checkout of PowerShell/PSReadLine. This script itself is
# intended to live at the repository root and be tracked as part of the local
# customization patch.
#
# Repository model:
#
#   upstream/<default>  = official https://github.com/PowerShell/PSReadLine
#   origin/<branch>     = your GitHub fork (not pushed by this baseline script)
#   HEAD                = latest official upstream + at most one local commit:
#                         "LOCAL: PSReadLine customizations"
#
# Default run:
#   * validates/adds the official 'upstream' remote
#   * fetches official upstream
#   * folds all working-tree changes into the local customization commit
#   * rebases the customization onto latest official upstream
#   * collapses multiple local commits back to one customization commit
#   * selects a dotnet host that satisfies global.json
#   * ensures InvokeBuild is available
#   * builds Release
#   * symlinks the built module into the first user PSModulePath directory
#
# A semantic Git conflict is intentionally not guessed at. The script leaves
# Git in its normal rebase state for manual resolution; rerere is enabled so
# Git can reuse successful resolutions later.
#
# This version intentionally does NOT push to origin yet. Fork synchronization
# is a separate policy decision because rebasing rewrites the customization
# commit and therefore eventually requires safe --force-with-lease handling.

[CmdletBinding()]
param(
    # Delete bin/ before building.
    [switch] $Clean,

    # Do not fetch/rebase official upstream. Working-tree changes are still
    # folded into the local customization commit before building.
    [switch] $NoSync
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$OfficialRepoUrl    = 'https://github.com/PowerShell/PSReadLine.git'
$LocalCommitMessage = 'LOCAL: PSReadLine customizations'

$RepoDir  = $PSScriptRoot
$BuildDir = Join-Path $RepoDir 'bin/Release/PSReadLine'
$Manifest = Join-Path $BuildDir 'PSReadLine.psd1'


function Get-NormalizedPath
{
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    [IO.Path]::TrimEndingDirectorySeparator(
        [IO.Path]::GetFullPath($Path)
    )
}


function Invoke-Git
{
    param(
        [Parameter(ValueFromRemainingArguments)]
        [string[]] $Arguments
    )

    # Native stdout written from inside a PowerShell function becomes part of
    # that function's return value. Send it to the host instead so mutating Git
    # commands can never accidentally contaminate callers that return data.
    & git -C $RepoDir @Arguments | Out-Host
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        throw "git $($Arguments -join ' ') failed with exit code $exitCode."
    }
}


function Get-GitScalar
{
    param(
        [switch] $AllowEmpty,

        [Parameter(ValueFromRemainingArguments)]
        [string[]] $Arguments
    )

    $output = @(& git -C $RepoDir @Arguments)

    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }

    if ($output.Count -eq 0 -and $AllowEmpty) {
        return ''
    }

    if ($output.Count -ne 1) {
        throw "Expected one line from 'git $($Arguments -join ' ')'; got $($output.Count)."
    }

    return [string] $output[0]
}


function Get-GitLines
{
    param(
        [Parameter(ValueFromRemainingArguments)]
        [string[]] $Arguments
    )

    $output = @(& git -C $RepoDir @Arguments)

    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }

    $output
}


function Get-RemoteUrl
{
    param(
        [Parameter(Mandatory)]
        [string] $Remote
    )

    Get-GitScalar remote get-url $Remote
}


function Test-IsOfficialRepoUrl
{
    param(
        [Parameter(Mandatory)]
        [string] $Url
    )

    $normalized = $Url.Trim().TrimEnd('/') -replace '\.git$', ''

    return $normalized -match '(?i)(?:github\.com[:/])PowerShell/PSReadLine$'
}


function Ensure-UpstreamRemote
{
    $remotes = @(Get-GitLines remote)

    if ($remotes -contains 'upstream') {
        $url = Get-RemoteUrl upstream

        if (-not (Test-IsOfficialRepoUrl $url)) {
            throw "Remote 'upstream' exists but does not point to PowerShell/PSReadLine: $url"
        }

        return 'upstream'
    }

    Write-Host "Adding official remote 'upstream' -> $OfficialRepoUrl" -ForegroundColor Cyan
    Invoke-Git remote add upstream $OfficialRepoUrl
    return 'upstream'
}


function Get-RemoteDefaultBranch
{
    param(
        [Parameter(Mandatory)]
        [string] $Remote
    )

    $ref = "refs/remotes/$Remote/HEAD"

    $head = @(
        & git -C $RepoDir symbolic-ref --quiet --short $ref 2>$null
    )

    if ($LASTEXITCODE -ne 0 -or $head.Count -eq 0) {
        Invoke-Git remote set-head $Remote --auto
        $head = @(Get-GitScalar symbolic-ref --quiet --short $ref)
    }

    $branch = ([string] $head[0]).Trim()

    if (-not $branch.StartsWith("$Remote/", [StringComparison]::Ordinal)) {
        throw "Unexpected $Remote HEAD: '$branch'."
    }

    return $branch
}


function Get-LocalCommitCount
{
    param(
        [Parameter(Mandatory)]
        [string] $Upstream
    )

    # Do NOT index [0] here. A scalar string '1' indexed as [0] becomes the
    # character '1', and [int][char]'1' is 49. Ask me how we know.
    return [int](Get-GitScalar rev-list --count "$Upstream..HEAD")
}


function Get-WorkingTreeChanges
{
    @(Get-GitLines status --porcelain=v1 --untracked-files=all)
}


function Test-GitOperationInProgress
{
    $gitDir = Get-GitScalar rev-parse --git-dir

    if (-not [IO.Path]::IsPathFullyQualified($gitDir)) {
        $gitDir = Join-Path $RepoDir $gitDir
    }

    foreach ($name in @(
        'rebase-merge'
        'rebase-apply'
        'MERGE_HEAD'
        'CHERRY_PICK_HEAD'
        'REVERT_HEAD'
    )) {
        if (Test-Path -LiteralPath (Join-Path $gitDir $name)) {
            return $true
        }
    }

    return $false
}


function Save-WorkingTreeToLocalPatch
{
    param(
        [Parameter(Mandatory)]
        [string] $Upstream
    )

    $changes = @(Get-WorkingTreeChanges)

    if ($changes.Count -eq 0) {
        return
    }

    Write-Host
    Write-Host 'Folding working-tree changes into local patch...' -ForegroundColor Cyan

    $changes | ForEach-Object {
        Write-Host "  $_"
    }

    $localCommitCount = Get-LocalCommitCount $Upstream

    Invoke-Git add --all

    if ($localCommitCount -eq 0) {
        Invoke-Git commit -m $LocalCommitMessage
    }
    else {
        # Amend the current tip first. If there are multiple local commits they
        # are collapsed, after rebasing, by Collapse-LocalCommits.
        Invoke-Git commit --amend --no-edit
    }
}


function Collapse-LocalCommits
{
    param(
        [Parameter(Mandatory)]
        [string] $Upstream
    )

    $count = Get-LocalCommitCount $Upstream

    if ($count -le 1) {
        return
    }

    Write-Host
    Write-Host "Collapsing $count local commits into one patch commit..." -ForegroundColor Cyan

    # After a successful rebase, Upstream is an ancestor of HEAD. A soft reset
    # keeps the combined local diff staged while discarding the local commit
    # boundaries, then we recreate exactly one customization commit.
    Invoke-Git reset --soft $Upstream
    Invoke-Git commit -m $LocalCommitMessage
}


function Get-UserModuleRoot
{
    $homePath = Get-NormalizedPath $HOME
    $comparison = if ($IsWindows) {
        [StringComparison]::OrdinalIgnoreCase
    }
    else {
        [StringComparison]::Ordinal
    }

    # Prefer the user's actual PSModulePath instead of guessing from $PROFILE.
    # On Linux this normally finds ~/.local/share/powershell/Modules.
    foreach ($candidate in $env:PSModulePath -split [IO.Path]::PathSeparator) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }

        try {
            $full = Get-NormalizedPath $candidate
            $prefix = $homePath + [IO.Path]::DirectorySeparatorChar

            if (
                [string]::Equals($full, $homePath, $comparison) -or
                $full.StartsWith($prefix, $comparison)
            ) {
                return $full
            }
        }
        catch {
        }
    }

    if ($IsWindows) {
        $documents = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)
        return Join-Path $documents 'PowerShell/Modules'
    }

    return Join-Path $HOME '.local/share/powershell/Modules'
}


function Test-PathInPSModulePath
{
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $wanted = Get-NormalizedPath $Path
    $comparison = if ($IsWindows) {
        [StringComparison]::OrdinalIgnoreCase
    }
    else {
        [StringComparison]::Ordinal
    }

    foreach ($candidate in $env:PSModulePath -split [IO.Path]::PathSeparator) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }

        try {
            if ([string]::Equals((Get-NormalizedPath $candidate), $wanted, $comparison)) {
                return $true
            }
        }
        catch {
        }
    }

    return $false
}


function Select-DotnetHost
{
    # global.json resolution is relative to the current directory, so call this
    # while RepoDir is current.

    $candidates = [Collections.Generic.List[string]]::new()

    foreach ($command in @(Get-Command dotnet -All -ErrorAction Ignore)) {
        if ($command.Source) {
            $candidates.Add($command.Source)
        }
    }

    if ($env:DOTNET_ROOT) {
        $candidates.Add((Join-Path $env:DOTNET_ROOT $(if ($IsWindows) { 'dotnet.exe' } else { 'dotnet' })))
    }

    $candidates.Add((Join-Path $HOME $(if ($IsWindows) { '.dotnet/dotnet.exe' } else { '.dotnet/dotnet' })))

    if ($IsWindows) {
        if ($env:ProgramFiles) {
            $candidates.Add((Join-Path $env:ProgramFiles 'dotnet/dotnet.exe'))
        }

        if ($env:LOCALAPPDATA) {
            $candidates.Add((Join-Path $env:LOCALAPPDATA 'Microsoft/dotnet/dotnet.exe'))
        }
    }

    $seen = [Collections.Generic.HashSet[string]]::new(
        $IsWindows ? [StringComparer]::OrdinalIgnoreCase : [StringComparer]::Ordinal)

    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }

        $candidate = Get-NormalizedPath $candidate

        if (-not $seen.Add($candidate)) {
            continue
        }

        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            continue
        }

        $version = @(& $candidate --version 2>$null)

        if ($LASTEXITCODE -ne 0 -or $version.Count -eq 0) {
            continue
        }

        $version = ([string] $version[0]).Trim()

        if (-not $version) {
            continue
        }

        $dotnetDir = Split-Path -Parent $candidate
        $wantedDir = Get-NormalizedPath $dotnetDir
        $comparison = if ($IsWindows) {
            [StringComparison]::OrdinalIgnoreCase
        }
        else {
            [StringComparison]::Ordinal
        }

        $remainingPath = @(
            $env:PATH -split [IO.Path]::PathSeparator |
                Where-Object {
                    if ([string]::IsNullOrWhiteSpace($_)) {
                        return $false
                    }

                    try {
                        -not [string]::Equals(
                            (Get-NormalizedPath $_),
                            $wantedDir,
                            $comparison
                        )
                    }
                    catch {
                        $true
                    }
                }
        )

        $env:PATH = @($dotnetDir; $remainingPath) -join [IO.Path]::PathSeparator

        Write-Host
        Write-Host "Using .NET SDK $version" -ForegroundColor Green
        Write-Host "  $candidate"
        return
    }

    throw "No dotnet installation could satisfy '$RepoDir/global.json'."
}


function Ensure-InvokeBuild
{
    if (Get-Module InvokeBuild -ListAvailable) {
        return
    }

    Write-Host 'Installing InvokeBuild...' -ForegroundColor Cyan

    if (Get-Command Install-PSResource -ErrorAction Ignore) {
        $gallery = Get-PSResourceRepository |
            Where-Object Name -EQ 'PSGallery' |
            Select-Object -First 1

        if (-not $gallery) {
            Register-PSResourceRepository -PSGallery
        }

        Install-PSResource InvokeBuild `
            -Repository PSGallery `
            -Scope CurrentUser `
            -TrustRepository

        return
    }

    if (Get-Command Install-Module -ErrorAction Ignore) {
        Install-Module InvokeBuild `
            -Repository PSGallery `
            -Scope CurrentUser `
            -Force

        return
    }

    throw 'Neither Install-PSResource nor Install-Module is available to install InvokeBuild.'
}


function Ensure-ModuleLink
{
    param(
        [Parameter(Mandatory)]
        [string] $UserModulesDir
    )

    New-Item -ItemType Directory -Path $UserModulesDir -Force | Out-Null

    $moduleLink   = Join-Path $UserModulesDir 'PSReadLine'
    $wantedTarget = Get-NormalizedPath $BuildDir
    $existing     = Get-Item -LiteralPath $moduleLink -Force -ErrorAction Ignore

    if ($existing) {
        if (-not $existing.LinkType) {
            throw @"
A real PSReadLine file/directory already exists at:

    $moduleLink

Refusing to remove it automatically. Move/remove that old copy once, then rerun.
"@
        }

        $targets = @($existing.Target) | ForEach-Object {
            if ([IO.Path]::IsPathFullyQualified($_)) {
                Get-NormalizedPath $_
            }
            else {
                Get-NormalizedPath (Join-Path (Split-Path -Parent $moduleLink) $_)
            }
        }

        $comparison = if ($IsWindows) {
            [StringComparison]::OrdinalIgnoreCase
        }
        else {
            [StringComparison]::Ordinal
        }

        $pointsToBuild = $false
        foreach ($target in $targets) {
            if ([string]::Equals($target, $wantedTarget, $comparison)) {
                $pointsToBuild = $true
                break
            }
        }

        if (-not $pointsToBuild) {
            Write-Host 'Replacing stale PSReadLine module link...' -ForegroundColor Cyan
            Remove-Item -LiteralPath $moduleLink -Force
            $existing = $null
        }
    }

    if (-not $existing) {
        Write-Host 'Creating PSReadLine module link...' -ForegroundColor Cyan

        try {
            New-Item `
                -ItemType SymbolicLink `
                -Path $moduleLink `
                -Target $BuildDir |
                Out-Null
        }
        catch {
            if (-not $IsWindows) {
                throw
            }

            Write-Warning 'Directory symlink creation failed; trying a Windows junction.'
            New-Item `
                -ItemType Junction `
                -Path $moduleLink `
                -Target $BuildDir |
                Out-Null
        }
    }

    return $moduleLink
}


# =============================================================================
# Repository
# =============================================================================

if (-not (Test-Path -LiteralPath (Join-Path $RepoDir '.git'))) {
    throw "SyncBuildPSReadLine.ps1 must live at the root of a PSReadLine Git checkout: $RepoDir"
}

$remotes = @(Get-GitLines remote)
if ($remotes -notcontains 'origin') {
    Write-Warning "No 'origin' remote exists. Expected origin to be your GitHub fork."
}

Invoke-Git config rerere.enabled true
Invoke-Git config rerere.autoupdate true

if (Test-GitOperationInProgress) {
    throw @"
A Git merge/rebase/cherry-pick/revert is already in progress.

Inspect it with:

    git -C '$RepoDir' status

Resolve/continue it, or abort it, before running this script again.
"@
}

$CurrentBranch = (Get-GitScalar -AllowEmpty branch --show-current).Trim()

if (-not $CurrentBranch) {
    throw 'PSReadLine is currently at a detached HEAD. Switch to a local branch first.'
}

$OfficialRemote = Ensure-UpstreamRemote

if (-not $NoSync) {
    Write-Host "Fetching official upstream from '$OfficialRemote'..." -ForegroundColor Cyan
    Invoke-Git fetch --prune $OfficialRemote
}

$Upstream = Get-RemoteDefaultBranch $OfficialRemote

# Ordering matters:
#   1. fetch first (safe with a dirty working tree)
#   2. commit/amend edits on their current base
#   3. rebase those edits onto fetched upstream
Save-WorkingTreeToLocalPatch $Upstream

$localCommitCount = Get-LocalCommitCount $Upstream

if (-not $NoSync) {
    Write-Host
    Write-Host "Branch:    $CurrentBranch"
    Write-Host "Official:  $Upstream"

    if ($localCommitCount -eq 0) {
        Write-Host 'No local patch commit; fast-forwarding to official upstream...' -ForegroundColor Cyan

        & git -C $RepoDir merge --ff-only $Upstream

        if ($LASTEXITCODE -ne 0) {
            throw "Could not fast-forward '$CurrentBranch' to '$Upstream'."
        }
    }
    else {
        Write-Host "Rebasing $localCommitCount local commit(s) onto official upstream..." -ForegroundColor Cyan

        & git -C $RepoDir rebase $Upstream

        if ($LASTEXITCODE -ne 0) {
            throw @"
The local PSReadLine customization conflicted with official upstream.

Git has intentionally been left in its normal rebase state.

Inspect:

    git -C '$RepoDir' status

Resolve conflicts, then:

    git -C '$RepoDir' add <resolved-files>
    git -C '$RepoDir' rebase --continue

Or abandon the attempted sync:

    git -C '$RepoDir' rebase --abort

rerere is enabled, so Git can reuse successful conflict resolutions later.
"@
        }
    }
}

Collapse-LocalCommits $Upstream

$localCommitCount = Get-LocalCommitCount $Upstream

if ($localCommitCount -gt 1) {
    throw "Internal error: expected at most one local commit; found $localCommitCount."
}


# =============================================================================
# Toolchain / build
# =============================================================================

Push-Location $RepoDir
try {
    Select-DotnetHost
    Ensure-InvokeBuild

    # build.ps1 imports tools/helper.psm1 without -Force. Evict any already
    # loaded copy so edits to helper.psm1 are actually observed in this pwsh.
    $helperPath = Get-NormalizedPath (Join-Path $RepoDir 'tools/helper.psm1')

    Get-Module |
        Where-Object {
            if (-not $_.Path) {
                return $false
            }

            try {
                (Get-NormalizedPath $_.Path) -eq $helperPath
            }
            catch {
                $false
            }
        } |
        Remove-Module -Force

    ./build.ps1 -Bootstrap

    if ($Clean) {
        $bin = Join-Path $RepoDir 'bin'

        if (Test-Path -LiteralPath $bin) {
            Write-Host 'Removing previous bin/ output...' -ForegroundColor Cyan
            Remove-Item -LiteralPath $bin -Recurse -Force
        }
    }

    Write-Host 'Building PSReadLine Release...' -ForegroundColor Cyan
    ./build.ps1 -Configuration Release
}
finally {
    Pop-Location
}

if (-not (Test-Path -LiteralPath $Manifest -PathType Leaf)) {
    throw "Build did not produce the expected module manifest: $Manifest"
}


# =============================================================================
# Expose built module through the user's PSModulePath
# =============================================================================

$UserModulesDir = Get-UserModuleRoot

if (-not (Test-PathInPSModulePath $UserModulesDir)) {
    Write-Warning "Chosen user module directory is not currently in PSModulePath: $UserModulesDir"
}

$ModuleLink = Ensure-ModuleLink -UserModulesDir $UserModulesDir


# =============================================================================
# Summary
# =============================================================================

$LocalCommit = $null

if ((Get-LocalCommitCount $Upstream) -eq 1) {
    $LocalCommit = Get-GitScalar log -1 --oneline "$Upstream..HEAD"
}

Write-Host
Write-Host 'PSReadLine ready.' -ForegroundColor Green
Write-Host
Write-Host "  Branch:    $CurrentBranch"
Write-Host "  Official:  $Upstream"
if (@(Get-GitLines remote) -contains 'origin') {
    Write-Host "  Fork:      origin -> $(Get-RemoteUrl origin)"
}
Write-Host "  Source:    $RepoDir"
Write-Host "  Build:     $BuildDir"
Write-Host "  Module:    $ModuleLink"
Write-Host "          -> $BuildDir"

if ($LocalCommit) {
    Write-Host "  Patch:     $LocalCommit"
}
else {
    Write-Host '  Patch:     none'
}

$loaded = Get-Module PSReadLine

if ($loaded) {
    Write-Host
    Write-Host 'This pwsh process already has PSReadLine loaded from:' -ForegroundColor Yellow
    Write-Host "  $($loaded.ModuleBase)"
    Write-Host 'Start a NEW pwsh process to load the rebuilt assembly.'
}

Write-Host
Write-Host 'Useful checks:'
Write-Host "  git -C '$RepoDir' status --short"
Write-Host "  git -C '$RepoDir' remote -v"
Write-Host "  git -C '$RepoDir' log --oneline --decorate --graph '$Upstream..HEAD'"
Write-Host "  Get-Module PSReadLine -ListAvailable | Format-List Name,Version,ModuleBase,Path"
