<#
.SYNOPSIS
    Reassemble the parts created by Torrent-To-GitHub.ps1 into the original file.

.DESCRIPTION
    Reads a "<Name>.manifest.json" file (produced by Torrent-To-GitHub.ps1 next
    to the parts), appends the parts in order to rebuild "<Name>", verifies the
    SHA-256 of each part and of the reassembled file, and reports any mismatch.

.PARAMETER ManifestPath
    Path to the manifest file (e.g. "C:\Downloads\movie.zip.manifest.json").

.EXAMPLE
    .\Reassemble.ps1 -ManifestPath "C:\Downloads\movie.zip.manifest.json"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [Alias('m')]
    [string]$ManifestPath
)

$ErrorActionPreference = 'Stop'

$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
$dir = $manifest.Dir
if (-not $dir) { $dir = (Get-Item -LiteralPath $ManifestPath).DirectoryName }
$outPath = [System.IO.Path]::Combine($dir, $manifest.Name)

$missing = $false
$outStream = [System.IO.File]::Create($outPath)
$total = 0
try {
    foreach ($p in $manifest.Parts) {
        $partPath = [System.IO.Path]::Combine($dir, $p.Name)
        if (-not (Test-Path -LiteralPath $partPath)) {
            Write-Host "MISSING PART: $partPath" -ForegroundColor Red
            $missing = $true
            continue
        }
        $hash = Get-FileHash -Algorithm SHA256 -LiteralPath $partPath
        if ($hash.Hash -ne $p.Sha256) {
            Write-Host "Part $($p.Name): hash mismatch (expected $($p.Sha256), got $($hash.Hash))" -ForegroundColor Red
        }
        $in = [System.IO.File]::OpenRead($partPath)
        $in.CopyTo($outStream)
        $total += $in.Length
        $in.Dispose()
    }
} finally {
    $outStream.Dispose()
}

$assembledHash = Get-FileHash -Algorithm SHA256 -LiteralPath $outPath
if ($manifest.Sha256) {
    if ($assembledHash.Hash -eq $manifest.Sha256) {
        Write-Host "Full-file hash OK: $($assembledHash.Hash)" -ForegroundColor Green
    } else {
        Write-Host "Full-file hash mismatch! Expected $($manifest.Sha256), got $($assembledHash.Hash)" -ForegroundColor Red
    }
}
Write-Host "Wrote $outPath ($total bytes)"
if ($missing) { exit 1 }
