# Build a Windows .msi from the Flutter release payload.
# Requires: Flutter, WiX Toolset CLI v4+ (winget install WiXToolset.WiXCLI)
#
# Usage:
#   powershell -File tool/build_msi.ps1
#   powershell -File tool/build_msi.ps1 -SkipFlutter

param(
  [switch]$SkipFlutter
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

function Find-Wix {
  $cmd = Get-Command wix -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $guess = 'C:\Program Files\WiX Toolset v7.0\bin\wix.exe'
  if (Test-Path $guess) { return $guess }
  throw @'
WiX CLI not found. Install it with:
  winget install --id WiXToolset.WiXCLI -e
Then re-run this script.
'@
}

$Wix = Find-Wix
Write-Host "Using WiX: $Wix"

if (-not $SkipFlutter) {
  Write-Host 'Building Flutter Windows release...'
  flutter build windows --release
}

$Payload = Join-Path $Root 'build\windows\x64\runner\Release'
$Exe = Join-Path $Payload 'bmp2tif_app.exe'
if (-not (Test-Path $Exe)) {
  throw "Missing $Exe — run flutter build windows --release first."
}

$Dist = Join-Path $Root 'dist'
New-Item -ItemType Directory -Force -Path $Dist | Out-Null
$Out = Join-Path $Dist 'Bmp2Tif.msi'

Write-Host "Building MSI -> $Out"
& $Wix build `
  -acceptEula wix7 `
  (Join-Path $Root 'installer\Package.wxs') `
  -arch x64 `
  -bindpath "payload=$Payload" `
  -o $Out

if ($LASTEXITCODE -ne 0) {
  throw "wix build failed with exit code $LASTEXITCODE"
}

Write-Host "Done: $Out"
Get-Item $Out | Format-List FullName, Length, LastWriteTime
