param(
  [switch]$Install,
  [string]$DriveRoot = "",
  [int]$PollSeconds = 10
)

$ErrorActionPreference = "Stop"
$WorkerName = $env:COMPUTERNAME
$AppRoot = Join-Path $env:LOCALAPPDATA "FlowOps"
$InstalledScript = Join-Path $AppRoot "flowops_drive_worker.ps1"
$StartupDir = [Environment]::GetFolderPath("Startup")
$StartupCmd = Join-Path $StartupDir "FlowOpsDriveWorker.cmd"

function Write-Log([string]$Message) {
  try {
    $root = Find-DriveRoot
    if ($root) {
      $logDir = Join-Path $root "FLOWOPS_CONTROL\99_LOGS"
      New-Item -ItemType Directory -Force -Path $logDir | Out-Null
      $line = "{0} [{1}] {2}" -f ([DateTime]::UtcNow.ToString("o")), $WorkerName, $Message
      Add-Content -Path (Join-Path $logDir ($WorkerName + ".log")) -Value $line -Encoding UTF8
    }
  } catch {}
}

function Find-DriveRoot {
  $candidates = New-Object System.Collections.Generic.List[string]
  if ($DriveRoot) { $candidates.Add($DriveRoot) }
  if ($env:FLOWOPS_DRIVE_ROOT) { $candidates.Add($env:FLOWOPS_DRIVE_ROOT) }
  $candidates.Add((Join-Path $env:USERPROFILE "Google Drive\My Drive\UGREEN NAS Sync"))
  $candidates.Add((Join-Path $env:USERPROFILE "My Drive\UGREEN NAS Sync"))
  foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
    $candidates.Add((Join-Path $d.Root "My Drive\UGREEN NAS Sync"))
    $candidates.Add((Join-Path $d.Root "UGREEN NAS Sync"))
  }
  foreach ($c in ($candidates | Select-Object -Unique)) {
    if ($c -and (Test-Path $c)) { return (Resolve-Path $c).Path }
  }
  return $null
}

function Write-AtomicJson([string]$Path, [object]$Object) {
  $tmp = $Path + ".tmp." + [guid]::NewGuid().ToString("N")
  $Object | ConvertTo-Json -Depth 10 | Set-Content -Path $tmp -Encoding UTF8
  Move-Item -Force -Path $tmp -Destination $Path
}

function Get-DiskInfo([string]$Path) {
  try {
    $root = [System.IO.Path]::GetPathRoot((Resolve-Path $Path).Path)
    $drive = Get-CimInstance Win32_LogicalDisk | Where-Object { $_.DeviceID -eq $root.TrimEnd("\") } | Select-Object -First 1
    if ($drive) {
      return @{ device=$drive.DeviceID; free_bytes=[int64]$drive.FreeSpace; size_bytes=[int64]$drive.Size; free_percent=[math]::Round(($drive.FreeSpace/$drive.Size)*100,2) }
    }
  } catch {}
  return @{}
}

function Invoke-Job([string]$Command, [string]$Arg, [string]$Root, [string]$JobId) {
  $base = @{
    job_id = $JobId
    command = $Command
    worker = $WorkerName
    completed_at = [DateTime]::UtcNow.ToString("o")
  }
  switch ($Command) {
    "PING" {
      $base.status = "PASS"
      $base.message = "FlowOps worker round-trip is alive."
      $base.hostname = $env:COMPUTERNAME
      $base.user = $env:USERNAME
      return $base
    }
    "HEALTH" {
      $base.status = "PASS"
      $base.hostname = $env:COMPUTERNAME
      $base.powershell = $PSVersionTable.PSVersion.ToString()
      $base.drive = Get-DiskInfo $Root
      $base.flowops_drive_root = $Root
      return $base
    }
    "INDEX_REFRESH" {
      $indexer = $env:FLOWOPS_INDEXER
      $config = $env:FLOWOPS_INDEX_CONFIG
      if (-not $indexer -or -not (Test-Path $indexer)) {
        $base.status = "BLOCKED"
        $base.error = "FLOWOPS_INDEXER is not configured or missing."
        return $base
      }
      if (-not $config -or -not (Test-Path $config)) {
        $base.status = "BLOCKED"
        $base.error = "FLOWOPS_INDEX_CONFIG is not configured or missing."
        return $base
      }
      $py = (Get-Command python -ErrorAction SilentlyContinue).Source
      if (-not $py) { $py = (Get-Command py -ErrorAction SilentlyContinue).Source }
      if (-not $py) {
        $base.status = "BLOCKED"
        $base.error = "Python is not available."
        return $base
      }
      try {
        $output = & $py $indexer --config $config --mode incremental 2>&1 | Out-String
        $base.exit_code = $LASTEXITCODE
        $base.status = if ($LASTEXITCODE -eq 0) { "PASS" } else { "FAIL" }
        $base.output_tail = if ($output.Length -gt 6000) { $output.Substring($output.Length-6000) } else { $output }
      } catch {
        $base.status = "FAIL"
        $base.error = $_.Exception.Message
      }
      return $base
    }
    default {
      $base.status = "REJECTED"
      $base.error = "Command is not on the FlowOps v1 allowlist."
      return $base
    }
  }
}

function Install-Worker {
  New-Item -ItemType Directory -Force -Path $AppRoot | Out-Null
  Copy-Item -Force -Path $PSCommandPath -Destination $InstalledScript
  if ($DriveRoot) {
    [Environment]::SetEnvironmentVariable("FLOWOPS_DRIVE_ROOT", $DriveRoot, "User")
    $env:FLOWOPS_DRIVE_ROOT = $DriveRoot
  }
  $cmd = "@echo off`r`nstart `"`" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$InstalledScript`"`r`n"
  Set-Content -Path $StartupCmd -Value $cmd -Encoding ASCII
  Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-File",$InstalledScript)
  Write-Host "FlowOps Drive worker installed and started for $WorkerName."
  Write-Host "Startup entry: $StartupCmd"
}

if ($Install) { Install-Worker; exit 0 }

$lastHeartbeat = [DateTime]::MinValue
while ($true) {
  try {
    $root = Find-DriveRoot
    if (-not $root) { Start-Sleep -Seconds 30; continue }

    $control = Join-Path $root "FLOWOPS_CONTROL"
    $inbox = Join-Path $control "00_INBOX"
    $claims = Join-Path $control "10_CLAIMS"
    $results = Join-Path $control "20_RESULTS"
    $heartbeats = Join-Path $control "90_HEARTBEATS"
    $logs = Join-Path $control "99_LOGS"
    foreach ($p in @($inbox,$claims,$results,$heartbeats,$logs)) { New-Item -ItemType Directory -Force -Path $p | Out-Null }

    if (([DateTime]::UtcNow - $lastHeartbeat).TotalSeconds -ge 45) {
      $hb = @{ worker=$WorkerName; status="ONLINE"; utc=[DateTime]::UtcNow.ToString("o"); drive_root=$root; disk=(Get-DiskInfo $root); poll_seconds=$PollSeconds; protocol="flowops-drive-v1" }
      Write-AtomicJson (Join-Path $heartbeats ($WorkerName + ".json")) $hb
      $lastHeartbeat = [DateTime]::UtcNow
    }

    foreach ($job in (Get-ChildItem -Path $inbox -Directory -ErrorAction SilentlyContinue)) {
      if ($job.Name -notmatch "^JOB--(?<id>[A-Za-z0-9-]+)--(?<cmd>[A-Z_]+)(--(?<arg>.*))?$") { continue }
      $jobId = $Matches.id
      $command = $Matches.cmd
      $arg = $Matches.arg
      $claimPath = Join-Path $claims $job.Name
      try {
        Move-Item -Path $job.FullName -Destination $claimPath -ErrorAction Stop
      } catch { continue }

      try {
        $result = Invoke-Job -Command $command -Arg $arg -Root $root -JobId $jobId
      } catch {
        $result = @{ job_id=$jobId; command=$command; worker=$WorkerName; status="FAIL"; error=$_.Exception.Message; completed_at=[DateTime]::UtcNow.ToString("o") }
      }
      $resultFile = Join-Path $claimPath ($jobId + "--result.json")
      Write-AtomicJson $resultFile $result
      $dest = Join-Path $results $job.Name
      try { Move-Item -Path $claimPath -Destination $dest -ErrorAction Stop } catch {}
      Write-Log ("completed " + $jobId + " " + $command + " " + $result.status)
    }
  } catch {
    Write-Log ("loop error: " + $_.Exception.Message)
  }
  Start-Sleep -Seconds $PollSeconds
}