$N8nRoot = Split-Path -Path $PSScriptRoot -Parent
$BridgeDir = Join-Path $N8nRoot 'baileys_bridge'

if (-not (Test-Path -LiteralPath $BridgeDir)) {
  throw "Diretorio do Baileys bridge nao encontrado: $BridgeDir"
}

$cmd = "Set-Location -LiteralPath '$BridgeDir'; npm.cmd start"
Start-Process -FilePath powershell.exe -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-Command', $cmd)