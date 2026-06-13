param(
  [string]$ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config.local.ps1')
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$workflowPath = Join-Path $projectRoot 'workflows\automacao-whatsapp-planilha.json'

if (-not (Test-Path -LiteralPath $ConfigPath)) {
  throw "Configuração não encontrada: $ConfigPath. Copie config.example.ps1 para config.local.ps1."
}

. $ConfigPath

if ([string]::IsNullOrWhiteSpace([string]$N8nUserFolder)) {
  throw 'Defina $N8nUserFolder em config.local.ps1.'
}

$n8nCommand = Get-Command n8n.cmd -ErrorAction SilentlyContinue
if (-not $n8nCommand) {
  throw 'n8n.cmd não encontrado. Instale com: npm install -g n8n'
}

New-Item -ItemType Directory -Path $N8nUserFolder -Force | Out-Null
$env:N8N_USER_FOLDER = [IO.Path]::GetFullPath($N8nUserFolder)

try {
  & $n8nCommand.Source import:workflow "--input=$workflowPath"
  if ($LASTEXITCODE -ne 0) {
    throw "A importação terminou com o código $LASTEXITCODE."
  }
}
finally {
  Remove-Item Env:N8N_USER_FOLDER -ErrorAction SilentlyContinue
}
