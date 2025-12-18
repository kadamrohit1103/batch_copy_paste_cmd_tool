<#
.SYNOPSIS
    Batch File Copier
    Copies files based on a CSV mapping.
    Supports copying from within ZIP archives.

.DESCRIPTION
    Reads a CSV file to copy files from Source to Destination.
    Handles conflict resolution by appending numbers.
    Supports Dry Run and Undo.
    Can extract specific files from Zip archives if the source path points inside one.

.PARAMETER inputfile
    Path to the .csv file.
    Col 1: Source Full Path (can be inside a zip, e.g. "C:\data.zip\folder\file.txt")
    Col 2: Destination Directory
    Col 3: (Optional) New Filename

.PARAMETER dryrun
    Preview operations.

.PARAMETER undo
    Deletes the files created by the last run.
#>

param(
    [string]$inputfile,
    [switch]$dryrun,
    [switch]$undo
)

$ErrorActionPreference = "Stop"
$LogFile = "copy_log.json" 

# Load Zip Assembly
Add-Type -AssemblyName System.IO.Compression.FileSystem

# --- Helper Functions ---

function Write-Success ($msg) { Write-Host "[SUCCESS] $msg" -ForegroundColor Green }
function Write-Warn ($msg)    { Write-Host "[WARNING] $msg" -ForegroundColor Yellow }
function Write-ErrorMsg ($msg){ Write-Host "[ERROR] $msg" -ForegroundColor Red }
function Write-Info ($msg)    { Write-Host "[INFO] $msg" -ForegroundColor Cyan }

function Get-UniqueFilename ($dir, $filename, $occupiedPaths) {
    $name = [System.IO.Path]::GetFileNameWithoutExtension($filename)
    $ext = [System.IO.Path]::GetExtension($filename)
    $count = 1
    $newVal = $filename
    
    # Check physical existence AND reserved paths
    while ((Test-Path (Join-Path $dir $newVal)) -or ($occupiedPaths -contains (Join-Path $dir $newVal))) {
        $newVal = "${name}_${count}${ext}"
        $count++
    }
    return $newVal
}

function Read-CsvData {
    param($Path)
    try {
        $headers = "Source","Dest","NewName"
        $data = Import-Csv $Path -Header $headers
        return $data
    }
    catch {
        Write-ErrorMsg "Failed to read CSV."
        return @()
    }
}

function Resolve-SourcePath ($path) {
    # Returns @{ Type="File"; Path=... } or @{ Type="Zip"; ZipPath=...; InnerPath=... }
    
    # 1. Check if direct file exists
    if (Test-Path -Path $path -PathType Leaf) {
        return @{ Type="File"; Path=$path }
    }

    # 2. Check if it's inside a zip
    # Traverse up looking for a .zip file
    $curr = $path
    $inner = @()
    
    while (-not [string]::IsNullOrEmpty($curr) -and $curr -ne [System.IO.Path]::GetPathRoot($curr)) {
        if ((Test-Path -Path $curr -PathType Leaf) -and ($curr -match "\.zip$")) {
            # Found the zip container
            $innerPath = $inner -join "/" # Zip entries use forward slashes usually
            
            # Verify entry exists in zip
            try {
                $zip = [System.IO.Compression.ZipFile]::OpenRead($curr)
                $entry = $zip.GetEntry($innerPath)
                $zip.Dispose()
                
                if ($entry) {
                    return @{ Type="Zip"; ZipPath=$curr; InnerPath=$innerPath }
                }
            } catch {
                # Zip error, ignore
            }
        }
        
        # Move up
        $inner = @([System.IO.Path]::GetFileName($curr)) + $inner
        $curr = [System.IO.Path]::GetDirectoryName($curr)
    }

    return $null
}

function Save-Log {
    param($ops)
    $batch = @{
        id = (Get-Date).Ticks
        timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        operations = $ops
    }
    
    $allLogs = @()
    if (Test-Path $LogFile) {
        try { $allLogs = Get-Content $LogFile -Raw | ConvertFrom-Json } catch {}
        if (-not $allLogs) { $allLogs = @() }
        if ($allLogs -isnot [array]) { $allLogs = @($allLogs) }
    }
    
    $allLogs += $batch
    $allLogs | ConvertTo-Json -Depth 4 | Set-Content $LogFile
}

function Undo-Last {
    if (-not (Test-Path $LogFile)) { Write-ErrorMsg "No undo log found ($LogFile)."; return }
    
    $json = Get-Content $LogFile -Raw | ConvertFrom-Json
    if (-not $json) { Write-Info "Log is empty."; return }
    if ($json -isnot [array]) { $json = @($json) }
    
    $lastBatch = $json[-1]
    Write-Info "Undoing Batch from $($lastBatch.timestamp)..."
    
    $ops = $lastBatch.operations
    foreach ($op in $ops) {
        $dest = $op.destination
        if (Test-Path $dest) {
            try {
                Remove-Item -LiteralPath $dest -Force
                Write-Success "Deleted: $dest"
            } catch {
                Write-ErrorMsg "Failed to delete '$dest': $($_.Exception.Message)"
            }
        }
    }
    
    # Remove from log
    $newJson = $json[0..($json.Count - 2)]
    if ($null -eq $newJson) { $newJson = @() }
    $newJson | ConvertTo-Json -Depth 4 | Set-Content $LogFile
}

# --- Main ---

if ($undo) {
    Undo-Last
    exit
}

if (-not $inputfile) { Write-ErrorMsg "Please provide -inputfile"; exit 1 }

$FullPathInput = Resolve-Path $inputfile
if (-not (Test-Path $FullPathInput)) { Write-ErrorMsg "CSV not found."; exit 1 }

$Data = Read-CsvData -Path $FullPathInput
$ops = @()
$OccupiedPaths = @()

foreach ($row in $Data) {
    $rawSrc = $row.Source
    $destDir = $row.Dest
    $preferred = $row.NewName

    if ([string]::IsNullOrWhiteSpace($rawSrc)) { continue }
    
    # 1. Resolve Source
    $srcInfo = Resolve-SourcePath -path $rawSrc
    
    if (-not $srcInfo) {
        Write-Warn "Source not found: '$rawSrc'. Skipping."
        continue
    }
    
    # 2. Check/Make Dest Dir
    if ([string]::IsNullOrWhiteSpace($destDir)) {
        Write-Warn "No destination for '$rawSrc'."
        continue
    }
    
    if (-not (Test-Path $destDir)) {
        if ($dryrun) {
            Write-Info "Would create directory: $destDir"
        } else {
            try { New-Item -Path $destDir -ItemType Directory -Force | Out-Null } catch {
                 Write-ErrorMsg "Failed to create directory $destDir"; continue
            }
        }
    }
    
    # 3. Determine Filename
    $baseName = ""
    if ($srcInfo.Type -eq "File") {
        $baseName = [System.IO.Path]::GetFileName($srcInfo.Path)
    } else {
        # Zip entry might contain slashes "folder/file.txt" -> "file.txt"
        $baseName = [System.IO.Path]::GetFileName($srcInfo.InnerPath)
    }
    
    $finalName = if (-not [string]::IsNullOrWhiteSpace($preferred)) { $preferred } else { $baseName }
    
    # 4. Conflict Resolution
    $finalName = Get-UniqueFilename -dir $destDir -filename $finalName -occupiedPaths $OccupiedPaths
    $fullDestPath = Join-Path $destDir $finalName
    
    # 5. Execute Copy/Extract
    if ($dryrun) {
        if ($srcInfo.Type -eq "file") {
            Write-Host "[PREVIEW] Copy '$($srcInfo.Path)' -> '$fullDestPath'" -ForegroundColor Cyan
        } else {
            Write-Host "[PREVIEW] Extract '$($srcInfo.ZipPath) :: $($srcInfo.InnerPath)' -> '$fullDestPath'" -ForegroundColor Cyan
        }
    } else {
        try {
            if ($srcInfo.Type -eq "File") {
                Copy-Item -LiteralPath $srcInfo.Path -Destination $fullDestPath -Force
                Write-Success "Copied: $finalName"
            } else {
                # Zip Extract
                $zip = [System.IO.Compression.ZipFile]::OpenRead($srcInfo.ZipPath)
                $entry = $zip.GetEntry($srcInfo.InnerPath)
                if ($entry) {
                    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $fullDestPath, $true)
                    Write-Success "Extracted: $finalName"
                } else {
                    Write-ErrorMsg "Zip entry missing during extract: $($srcInfo.InnerPath)"
                }
                $zip.Dispose()
            }
            $ops += @{ source = $rawSrc; destination = $fullDestPath }
        } catch {
            Write-ErrorMsg "Failed to process '$rawSrc': $($_.Exception.Message)"
        }
    }
    
    $OccupiedPaths += $fullDestPath
}

if (-not $dryrun -and $ops.Count -gt 0) {
    Save-Log $ops
    Write-Host "Tip: Undo with copy_tool.bat -undo" -ForegroundColor Magenta
}

Write-Info "Done."
