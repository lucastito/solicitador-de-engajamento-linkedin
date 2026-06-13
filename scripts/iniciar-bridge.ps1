param(
  [string]$ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config.local.ps1')
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$bridgeRoot = Join-Path $projectRoot 'baileys_bridge'

if (-not (Test-Path -LiteralPath $ConfigPath)) {
  throw "Configuração não encontrada: $ConfigPath. Copie config.example.ps1 para config.local.ps1."
}

. $ConfigPath

$port = if ($BaileysPort) { [int]$BaileysPort } else { 4010 }
$authDir = Join-Path $bridgeRoot 'session'

New-Item -ItemType Directory -Path $authDir -Force | Out-Null

if (-not (Test-Path -LiteralPath (Join-Path $bridgeRoot 'node_modules'))) {
  npm.cmd ci --prefix $bridgeRoot
  if ($LASTEXITCODE -ne 0) {
    throw "A instalação das dependências terminou com o código $LASTEXITCODE."
  }
}

$env:BAILEYS_HOST = '127.0.0.1'
$env:BAILEYS_PORT = "$port"
$env:BAILEYS_AUTH_DIR = $authDir

try {
  Push-Location $bridgeRoot
  npm.cmd start
}
finally {
  Pop-Location
  Remove-Item Env:BAILEYS_HOST,Env:BAILEYS_PORT,Env:BAILEYS_AUTH_DIR -ErrorAction SilentlyContinue
}
