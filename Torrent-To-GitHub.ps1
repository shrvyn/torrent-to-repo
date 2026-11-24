<#
.SYNOPSIS
    Torrent-To-GitHub: download from a torrent, split every file into <= 2 GiB
    parts, upload them to a new GitHub repository and print direct download links.

.DESCRIPTION
    Pipeline:
      1. Download the magnet URI / .torrent file with aria2c (auto-downloaded
         from aria2's GitHub releases if not on PATH) into <OutDir>\downloads.
      2. Chunk phase: every downloaded file is streamed to parts named
         "<Name>.part0001", "<Name>.part0002", ... capped at 2 GiB, and a
         per-file manifest "<Name>.manifest.json" is written next to the parts.
         Each manifest lists the parts with their SHA-256 hashes and the
         SHA-256 of the original file, so the download can be verified and the
         file reassembled.
      3. GitHub phase: creates a repository (if needed), creates a release,
         uploads every part as a release asset and commits the manifests.

    Local files are also accepted as -Source (with -SkipDownload), which is
    handy for testing or for chunking files you already have.

.PARAMETER Source
    A magnet URI, .torrent file path, local file path, or local directory.

.PARAMETER OutDir
    Working directory for downloads and parts. Default: <script dir>\downloads.

.PARAMETER ChunkSizeBytes
    Maximum size of each part, in bytes. Default: 2 GiB (2147483648), the GitHub
    repo-file limit. Lower it if your GitHub plan/limit is smaller.

.PARAMETER RepoName
    Name of the GitHub repository to create. Default: derived from the file
    names, or "torrent-chunks-<date>".

.PARAMETER Owner
    GitHub account that owns the repository. Default: the token's user.

.PARAMETER Token
    GitHub personal access token with the "repo" scope. Default: $env:GITHUB_TOKEN
    or an interactive prompt.

.PARAMETER Force
    Skip the confirmation prompt before creating the repository.

.PARAMETER SkipDownload
    Do not run aria2c; chunk files already in <OutDir>.

.PARAMETER SkipGitHub
    Stop after chunking (no upload to GitHub).

.EXAMPLE
    .\Torrent-To-GitHub.ps1 -Source "magnet:?xt=urn:btih:ABCDEF..." -RepoName "my-torrents"

.EXAMPLE
    .\Torrent-To-GitHub.ps1 -Source C:\Downloads\movie.torrent -SkipGitHub
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [Alias('s')]
    [string]$Source,

    [Parameter()]
    [Alias('o')]
    [string]$OutDir,

    [Parameter()]
    [Alias('c')]
    [int64]$ChunkSizeBytes = 2147483648,

    [Parameter()]
    [Alias('r')]
    [string]$RepoName,

    [Parameter()]
    [Alias('u')]
    [string]$Owner,

    [Parameter()]
    [Alias('t')]
    [string]$Token,

    [Parameter()]
    [Alias('f')]
    [switch]$Force,

    [Parameter()]
    [switch]$SkipDownload,

    [Parameter()]
    [switch]$SkipGitHub
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- helpers

function Write-Step {
    param([string]$Message)
    Write-Host ("`n== " + $Message) -ForegroundColor Cyan
}

function Write-Fail {
    param([string]$Message)
    Write-Host ("ERROR: " + $Message) -ForegroundColor Red
    exit 1
}

# Call GitHub REST API; returns the parsed response object, or $null via
# Invoke-ApiTry when the call fails (non-existent repo, etc.).
function Invoke-Api {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Uri,
        [string]$Token,
        $Body,
        [string]$InFile
    )
    $params = @{
        Method          = $Method
        Uri             = $Uri
        UseBasicParsing = $true
        ErrorAction     = 'Stop'
    }
    if ($Token) {
        $params.Headers = @{ Authorization = "Bearer $Token"; Accept = 'application/vnd.github+json' }
    }
    if ($InFile) {
        $params.InFile = $InFile
    } elseif ($Body) {
        $params.Body        = ($Body | ConvertTo-Json -Depth 10 -Compress)
        $params.ContentType = 'application/json'
    }
    $response = Invoke-WebRequest @params
    if ($response.Content) {
        return ($response.Content | ConvertFrom-Json)
    }
    return $response
}

function Invoke-ApiTry {
    param([string]$Method, [string]$Uri, [string]$Token, $Body, [string]$InFile)
    try { Invoke-Api -Method $Method -Uri $Uri -Token $Token -Body $Body -InFile $InFile }
    catch { $null }
}

# Find or download aria2c. Returns the path to aria2c.exe.
function Ensure-Aria2c {
    param([string]$ToolsDir)
    $existing = Get-Command aria2c -ErrorAction SilentlyContinue
    if ($existing) { return $existing.Source }
    $aria2cPath = Join-Path $ToolsDir 'aria2c.exe'
    if (Test-Path -LiteralPath $aria2cPath) { return $aria2cPath }

    Write-Step 'Downloading aria2c (the BitTorrent client)'
    New-Item -ItemType Directory -Force -Path $ToolsDir | Out-Null
    try {
        $latest = Invoke-Api -Method GET -Uri 'https://api.github.com/repos/aria2/aria2/releases/latest'
        $winAsset = $latest.Assets | Where-Object { $_.Name -match 'win-64bit' } | Select-Object -First 1
        if (-not $winAsset) { $winAsset = $latest.Assets | Where-Object { $_.Name -like '*.zip' } | Select-Object -First 1 }
        if (-not $winAsset) { Write-Fail 'Could not find an aria2c Windows release asset.' }
        $zipPath = Join-Path $ToolsDir 'aria2.zip'
        Invoke-WebRequest -Uri $winAsset.browser_download_url -OutFile $zipPath -UseBasicParsing
        Expand-Archive -Path $zipPath -DestinationPath $ToolsDir -Force
        $found = Get-ChildItem -LiteralPath $ToolsDir -Filter aria2c.exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $found) { Write-Fail 'aria2c.exe not found after extraction.' }
        return $found.FullName
    } catch {
        Write-Fail "Could not download aria2c automatically. Install it yourself (https://aria2.github.io/) and retry: $_"
    }
}

# Chunk one file into parts of at most $ChunkSizeBytes and write its manifest.
# Returns a manifest hashtable.
function New-ChunksForFile {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][int64]$ChunkSizeBytes
    )
    $base = [System.IO.Path]::GetFullPath($FilePath)
    $dir  = [System.IO.Path]::GetDirectoryName($base)
    $name = [System.IO.Path]::GetFileName($base)
    $size = (Get-Item -LiteralPath $base).Length
    if ($size -eq 0) { Write-Host "   $name (0 bytes, skipped)"; return $null }

    Write-Host "   $name ($('{0:N2}' -f ($size / 1MB)) MB)"

    $fullHasher = [System.Security.Cryptography.SHA256]::Create()
    $parts = @()
    $stream = [System.IO.File]::OpenRead($base)
    try {
        $buffer = New-Object Byte[]($ChunkSizeBytes)
        $partIdx = 0
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $fullHasher.TransformBlock($buffer, 0, $read, $null, 0)
            $partIdx++
            $partPath = [System.IO.Path]::Combine($dir, "$name.part{0:D4}" -f $partIdx)
            $out = [System.IO.File]::Create($partPath)
            try { $out.Write($buffer, 0, $read) } finally { $out.Dispose() }
            $partHash = Get-FileHash -Algorithm SHA256 -LiteralPath $partPath
            $parts += @{ Name = [System.IO.Path]::GetFileName($partPath); Size = $read; Sha256 = $partHash.Hash }
        }
        $fullHasher.TransformFinalBlock((New-Object Byte[](0)), 0, 0)
        $fullHashHex = [BitConverter]::ToString($fullHasher.Hash).Replace('-', '').ToLower()
    } finally {
        $stream.Dispose()
        $fullHasher.Dispose()
    }

    $manifest = @{
        Dir    = $dir
        Name   = $name
        Size   = $size
        Sha256 = $fullHashHex
        Parts  = $parts
    }
    $manifestPath = [System.IO.Path]::Combine($dir, "$name.manifest.json")
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    return $manifest
}

# ---------------------------------------------------------------- main

if ($ChunkSizeBytes -le 0) { Write-Fail '-ChunkSizeBytes must be a positive number of bytes.' }

if (-not $OutDir) {
    $OutDir = Join-Path (Split-Path -Parent (Get-Item -LiteralPath $PSCommandPath).FullName) 'downloads'
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$sourceIsFile = Test-Path -LiteralPath $Source -PathType Leaf
$sourceIsDir = Test-Path -LiteralPath $Source -PathType Container

$sourceDir   = $null
$sourceFiles = $null
if ($sourceIsFile) {
    $sourceDir   = (Get-Item -LiteralPath $Source).DirectoryName
    $sourceFiles = @(Get-ChildItem -LiteralPath $Source)
} elseif ($sourceIsDir) {
    $sourceDir = (Get-Item -LiteralPath $Source).FullName
}

if (-not $sourceDir) {
    # Not a local path: it is a magnet URI or .torrent path -> download with aria2c.
    if ($SkipDownload) { Write-Fail '-Source is not a local file/directory and -SkipDownload is set.' }
    $A2 = Ensure-Aria2c -ToolsDir (Join-Path $OutDir 'tools')
    $dlDir = Join-Path $OutDir 'downloads'
    New-Item -ItemType Directory -Force -Path $dlDir | Out-Null
    Write-Step 'Downloading torrent with aria2c (this can take a while)'
    & $A2 -d $dlDir $Source
    if ($LASTEXITCODE -ne 0) { Write-Fail "aria2c exited with code $LASTEXITCODE. Check the output above." }
    $sourceDir = $dlDir
} else {
    if (-not $SkipDownload) { Write-Host "Local source found: $sourceDir" }
}

# ---- Step 2: chunk
Write-Step 'Chunking files'
$manifests = @()
$files = if ($sourceFiles) {
    $sourceFiles
} else {
    Get-ChildItem -LiteralPath $sourceDir -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '\.part\d+$' -and $_.Extension -ne '.json' }
}
if (-not $files) { Write-Fail "No files to chunk in $sourceDir." }
foreach ($f in $files) {
    $manifest = New-ChunksForFile -FilePath $f.FullName -ChunkSizeBytes $ChunkSizeBytes
    if ($manifest) { $manifests += $manifest }
}

# ---- Step 3: GitHub
if (-not $SkipGitHub) {
    Write-Step 'Connecting to GitHub'

    if (-not $Token) { $Token = $env:GITHUB_TOKEN }
    if (-not $Token) {
        $cred = Get-Credential -Message 'GitHub: enter a personal access token with the "repo" scope (any user name works).'
        $Token = $cred.GetNetworkCredential().Password
    }
    if (-not $Token) { Write-Fail 'No GitHub token provided.' }

    if (-not $Owner) {
        $me = Invoke-Api -Method GET -Uri 'https://api.github.com/user' -Token $Token
        $Owner = $me.login
    }

    if (-not $RepoName) {
        $first = ($manifests | Select-Object -First 1).Name
        $RepoName = ($first -replace '[^A-Za-z0-9_.-]', '-').Trim('-.')
        if (-not $RepoName) { $RepoName = "torrent-chunks-$(Get-Date -Format 'yyyyMMdd')" }
    }

    $repoObj = Invoke-ApiTry -Method GET -Uri "https://api.github.com/repos/$Owner/$RepoName" -Token $Token
    if (-not $repoObj) {
        Write-Step "Creating repository $Owner/$RepoName"
        if (-not $Force) {
            $ok = Read-Host "Create GitHub repository '$Owner/$RepoName'? (y/N)"
            if ($ok -notmatch '^[yY]') { Write-Host 'Aborted.'; return }
        }
        $repoObj = Invoke-Api -Method POST -Uri 'https://api.github.com/user/repos' -Token $Token -Body @{
            name        = $RepoName
            private     = $false
            auto_init   = $true
            description = 'Torrent parts created by Torrent-To-GitHub.'
        }
    }
    $branch = $repoObj.DefaultBranch

    $tag = "chunks-" + (Get-Date).ToString('yyyyMMddTHHmmss')
    $release = Invoke-Api -Method POST -Uri "https://api.github.com/repos/$Owner/$RepoName/releases" -Token $Token -Body @{
        tag_name = $tag
        name     = $tag
        body     = ('Torrent parts for: ' + (($manifests | ForEach-Object { $_.Name }) -join ', '))
    }

    Write-Step "Uploading parts (release $tag)"
    $links = @()
    foreach ($m in $manifests) {
        foreach ($p in $m.Parts) {
            $assetPath = Join-Path $m.Dir $p.Name
            Write-Host "   Uploading $($p.Name) ($([math]::Round($p.Size / 1MB, 1)) MB)"
            Invoke-WebRequest -Method PUT `
                -Uri "https://uploads.github.com/repos/$Owner/$RepoName/releases/$($release.id)/assets?name=$([System.Uri]::EscapeDataString($p.Name))" `
                -InFile $assetPath -UseBasicParsing -ErrorAction Stop | Out-Null
            $links += "https://github.com/$Owner/$RepoName/releases/download/$tag/$($p.Name)"
        }
        # Commit the manifest into the repository.
        $manifestRelPath = "manifests/$($m.Name).manifest.json"
        $localManifestPath = Join-Path $m.Dir "$($m.Name).manifest.json"
        $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes((Get-Content -LiteralPath $localManifestPath -Raw)))
        Invoke-Api -Method PUT -Uri "https://api.github.com/repos/$Owner/$RepoName/contents/$manifestRelPath" -Token $Token -Body @{
            message = "Add manifest $($m.Name).manifest.json"
            content = $b64
            branch  = $branch
        } | Out-Null
    }

    Write-Step 'Done'
    Write-Host "Repository:  https://github.com/$Owner/$RepoName"
    Write-Host "Release:     https://github.com/$Owner/$RepoName/releases/tag/$tag"
    if ($links.Count) {
        Write-Host "Part links:"
        $links | ForEach-Object { Write-Host "   $_" }
    }
    Write-Host "Manifest files are committed in the repo (folder 'manifests/'); run Reassemble.ps1 to rebuild."
}

if ($SkipGitHub) {
    Write-Host ""
    Write-Host "Chunking complete. Parts are in $sourceDir (use Reassemble.ps1 to rebuild)."
}
