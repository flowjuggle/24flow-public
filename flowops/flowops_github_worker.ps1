param(
  [switch]$Install,
  [string]$Repo = "flowjuggle/yt_screenshot_tool",
  [int]$PollSeconds = 12
)

$ErrorActionPreference = "Stop"
$Worker = $env:COMPUTERNAME
$AppRoot = Join-Path $env:LOCALAPPDATA "FlowOps"
$InstalledScript = Join-Path $AppRoot "flowops_github_worker.ps1"
$StateFile = Join-Path $AppRoot "processed_issues.json"
$StartupDir = [Environment]::GetFolderPath("Startup")
$StartupCmd = Join-Path $StartupDir "FlowOpsGitHubWorker.cmd"

function Ensure-Gh {
  $gh = Get-Command gh -ErrorAction SilentlyContinue
  if (-not $gh) { throw "GitHub CLI (gh) is not installed." }
  & gh auth status 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "GitHub CLI is installed but not authenticated. Run: gh auth login" }
}

function Load-State {
  if (Test-Path $StateFile) {
    try { return @(Get-Content $StateFile -Raw | ConvertFrom-Json) } catch {}
  }
  return @()
}

function Save-State([object[]]$Ids) {
  New-Item -ItemType Directory -Force -Path $AppRoot | Out-Null
  @($Ids | Sort-Object -Unique | Select-Object -Last 500) | ConvertTo-Json | Set-Content $StateFile -Encoding UTF8
}

function Post-Comment([int]$Number,[string]$Body) {
  $tmp = Join-Path $env:TEMP ("flowops-comment-" + [guid]::NewGuid().ToString("N") + ".txt")
  Set-Content -Path $tmp -Value $Body -Encoding UTF8
  & gh issue comment $Number --repo $Repo --body-file $tmp | Out-Null
  Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}

function Execute-Allowlisted([string]$Command,[hashtable]$Job,[int]$Issue) {
  $result = [ordered]@{
    protocol="flowops-github-v1"; issue=$Issue; job_id=$Job.job_id; command=$Command;
    worker=$Worker; completed_at=[DateTime]::UtcNow.ToString("o")
  }
  switch ($Command) {
    "PING" {
      $result.status="PASS"; $result.message="GitHub control path round-trip is alive."; return $result
    }
    "HEALTH" {
      $result.status="PASS"; $result.hostname=$Worker; $result.user=$env:USERNAME;
      $result.powershell=$PSVersionTable.PSVersion.ToString();
      $result.os=(Get-CimInstance Win32_OperatingSystem | Select-Object Caption,Version,LastBootUpTime);
      $result.drives=@(Get-CimInstance Win32_LogicalDisk | Where-Object DriveType -eq 3 | Select-Object DeviceID,Size,FreeSpace);
      return $result
    }
    "INDEX_REFRESH" {
      $indexer=$env:FLOWOPS_INDEXER; $config=$env:FLOWOPS_INDEX_CONFIG
      if(-not $indexer -or -not (Test-Path $indexer)){ $result.status="BLOCKED"; $result.error="FLOWOPS_INDEXER missing"; return $result }
      if(-not $config -or -not (Test-Path $config)){ $result.status="BLOCKED"; $result.error="FLOWOPS_INDEX_CONFIG missing"; return $result }
      $py=(Get-Command python -ErrorAction SilentlyContinue).Source
      if(-not $py){ $py=(Get-Command py -ErrorAction SilentlyContinue).Source }
      if(-not $py){ $result.status="BLOCKED"; $result.error="Python missing"; return $result }
      $out=& $py $indexer --config $config --mode incremental 2>&1 | Out-String
      $result.exit_code=$LASTEXITCODE; $result.status=if($LASTEXITCODE -eq 0){"PASS"}else{"FAIL"}
      $result.output_tail=if($out.Length -gt 6000){$out.Substring($out.Length-6000)}else{$out}
      return $result
    }
    default { $result.status="REJECTED"; $result.error="Command is not allowlisted."; return $result }
  }
}

function Install-Worker {
  Ensure-Gh
  New-Item -ItemType Directory -Force -Path $AppRoot | Out-Null
  Copy-Item -Force $PSCommandPath $InstalledScript
  $cmd="@echo off`r`nstart `"`" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$InstalledScript`"`r`n"
  Set-Content -Path $StartupCmd -Value $cmd -Encoding ASCII
  Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-File",$InstalledScript)
  Write-Host "FLOWOPS_GITHUB_WORKER_INSTALLED worker=$Worker repo=$Repo"
}

if($Install){ Install-Worker; exit 0 }
Ensure-Gh
$processed=Load-State
while($true){
  try {
    $raw=& gh issue list --repo $Repo --state open --search "FLOWOPS-JOB in:title" --limit 20 --json number,title,body 2>$null
    if($LASTEXITCODE -ne 0){ throw "gh issue list failed" }
    $issues=@($raw | ConvertFrom-Json)
    foreach($i in $issues){
      if($processed -contains [int]$i.number){ continue }
      try { $job=$i.body | ConvertFrom-Json -AsHashtable } catch { continue }
      if(-not $job.job_id -or -not $job.command){ continue }
      if($job.target){
        $target=[string]$job.target
        if($Worker -notlike ("*"+$target+"*")){ continue }
      }
      Post-Comment ([int]$i.number) ("FLOWOPS_CLAIM worker="+$Worker+" utc="+[DateTime]::UtcNow.ToString("o"))
      $res=Execute-Allowlisted ([string]$job.command).ToUpperInvariant() $job ([int]$i.number)
      $json=$res | ConvertTo-Json -Depth 8
      Post-Comment ([int]$i.number) ("FLOWOPS_RESULT`n```json`n"+$json+"`n```")
      & gh issue close ([int]$i.number) --repo $Repo --reason completed | Out-Null
      $processed += [int]$i.number; Save-State $processed
    }
  } catch { Start-Sleep -Seconds 20 }
  Start-Sleep -Seconds $PollSeconds
}