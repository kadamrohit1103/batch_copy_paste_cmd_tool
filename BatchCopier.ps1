<#
.SYNOPSIS
    Batch File Copier
    Copies files based on a CSV mapping.

.DESCRIPTION
    Reads a CSV file to copy files from Source to Destination.
    Handles conflict resolution by appending numbers.
    Supports Dry Run and Undo.

.PARAMETER inputfile
    Path to the .csv file.
    Col 1: Source Full Path
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
        # Read CSV without headers to treat as Index 0, 1, 2
        # We manually parse lines to be robust against "header or no header" ambiguity if possible,
        # but Import-Csv -Header is safest to normalize.
        $headers = "Source","Dest","NewName"
        $data = Import-Csv $Path -Header $headers
        
        # If the first row looks like a header (e.g. "Source Path" or similar), we might skip it.
        # Simple heuristic: If "Source" path doesn't exist and looks like text, skip.
        # But user might have headers. Let's just assume valid data starts from row 2 if row 1 is invalid?
        # Actually, let's keep it simple: ALL rows are processed. If row 1 fails validation, it's skipped.
        return $data
    }
    catch {
        Write-ErrorMsg "Failed to read CSV."
        return @()
    }
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
        } else {
            Write-Warn "File not found (already gone?): $dest"
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
    $src = $row.Source
    $destDir = $row.Dest
    $preferred = $row.NewName

    if ([string]::IsNullOrWhiteSpace($src)) { continue }
    
    # Check Source
    if (-not (Test-Path $src)) {
        # Check if it was a header row?
        # If $src is "Source Path" or similar, just skip silently or warn?
        # Let's warn.
        Write-Warn "Source not found: '$src'. Skipping."
        continue
    }
    
    # Prepare Dest
    if ([string]::IsNullOrWhiteSpace($destDir)) {
        Write-Warn "Destination missing for '$src'. Skipping."
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
    
    # Resolution of Filename
    $finalName = if (-not [string]::IsNullOrWhiteSpace($preferred)) { $preferred } else { [System.IO.Path]::GetFileName($src) }
    
    # Conflict Resolution
    $finalName = Get-UniqueFilename -dir $destDir -filename $finalName -occupiedPaths $OccupiedPaths
    $fullDestPath = Join-Path $destDir $finalName
    
    # Action
    if ($dryrun) {
        Write-Host "[PREVIEW] Copy '$src' -> '$fullDestPath'" -ForegroundColor Cyan
    } else {
        try {
            Copy-Item -LiteralPath $src -Destination $fullDestPath -Force
            Write-Success "Copied to '$fullDestPath'"
            $ops += @{ source = $src; destination = $fullDestPath }
        } catch {
            Write-ErrorMsg "Failed to copy: $($_.Exception.Message)"
        }
    }
    
    $OccupiedPaths += $fullDestPath
}

if (-not $dryrun -and $ops.Count -gt 0) {
    Save-Log $ops
    Write-Host "Tip: Undo with copy_tool.bat -undo" -ForegroundColor Magenta
}

Write-Info "Done."
