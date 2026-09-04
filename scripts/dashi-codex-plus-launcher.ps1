param(
  [switch]$InstallStartup,
  [string]$DataDirectory
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$dataDirectory = if ($DataDirectory) { [System.IO.Path]::GetFullPath($DataDirectory) } else { Join-Path $projectRoot ".data" }
$injectorPath = Join-Path $projectRoot "scripts\codex-injector.mjs"
$cdpUrl = "http://127.0.0.1:9229/json/version"

New-Item -ItemType Directory -Force -Path $dataDirectory | Out-Null

$appPackage = Get-AppxPackage -Name OpenAI.Codex -ErrorAction Stop
if (-not $appPackage.InstallLocation) {
  throw "OpenAI.Codex Appx package is not installed"
}
$appPath = Join-Path $appPackage.InstallLocation "app\ChatGPT.exe"
if (-not (Test-Path -LiteralPath $appPath -PathType Leaf)) {
  throw "Codex executable not found at $appPath"
}

$nodeCommand = Get-Command node -ErrorAction Stop
$outputLog = Join-Path $dataDirectory "dashi-codex-plus.log"
$errorLog = Join-Path $dataDirectory "dashi-codex-plus.error.log"

function Test-CodexCdp {
  try {
    $response = Invoke-WebRequest -UseBasicParsing -Uri $cdpUrl -TimeoutSec 2
    return $response.StatusCode -eq 200
  } catch {
    return $false
  }
}

if ($InstallStartup) {
  $startupDirectory = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup"
  New-Item -ItemType Directory -Force -Path $startupDirectory | Out-Null
  $shortcutPath = Join-Path $startupDirectory "Dashi Taskboard Codex++ Launcher.lnk"
  $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcutPath)
  $shortcut.TargetPath = (Get-Command powershell.exe).Source
  $shortcut.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -DataDirectory `"$dataDirectory`""
  $shortcut.WorkingDirectory = $projectRoot
  $shortcut.Save()
  Write-Output "Created $shortcutPath"
  return
}

$env:CODEX_TASKBOARD_HOST = "127.0.0.1"
$env:CODEX_TASKBOARD_PORT = "47823"
$env:CODEX_TASKBOARD_DATA_DIR = $dataDirectory

while ($true) {
  while (-not (Test-CodexCdp)) {
    Start-Sleep -Seconds 2
  }

  $arguments = @(
    $injectorPath
    "--watch"
    "--open"
    "--port"
    "9229"
    "--app-path"
    "`"$appPath`""
  )
  $process = Start-Process `
    -FilePath $nodeCommand.Source `
    -ArgumentList $arguments `
    -WorkingDirectory $projectRoot `
    -WindowStyle Hidden `
    -RedirectStandardOutput $outputLog `
    -RedirectStandardError $errorLog `
    -PassThru
  $process.WaitForExit()
  Start-Sleep -Seconds 2
}
