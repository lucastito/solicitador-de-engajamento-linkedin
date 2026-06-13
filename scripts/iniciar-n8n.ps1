param(
  [string]$ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config.local.ps1')
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ConfigPath)) {
  throw "Configuração não encontrada: $ConfigPath. Copie config.example.ps1 para config.local.ps1."
}

. $ConfigPath

$requiredValues = @{
  SolicitadorRoot = $SolicitadorRoot
  Planilha = $Planilha
  N8nUserFolder = $N8nUserFolder
}

foreach ($entry in $requiredValues.GetEnumerator()) {
  if ([string]::IsNullOrWhiteSpace([string]$entry.Value)) {
    throw "Defina `$$($entry.Key) em config.local.ps1."
  }
}

if (-not (Test-Path -LiteralPath $Planilha -PathType Leaf)) {
  throw "Planilha não encontrada: $Planilha"
}

$n8nCommand = Get-Command n8n.cmd -ErrorAction SilentlyContinue
if (-not $n8nCommand) {
  throw 'n8n.cmd não encontrado. Instale com: npm install -g n8n'
}

$port = if ($N8nPort) { [int]$N8nPort } else { 5679 }
$baileysPortValue = if ($BaileysPort) { [int]$BaileysPort } else { 4010 }
$timeZoneValue = if ($Timezone) { [string]$Timezone } else { 'America/Sao_Paulo' }
$dryRunValue = if ($DryRun -eq $false) { 'false' } else { 'true' }

New-Item -ItemType Directory -Path $N8nUserFolder -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $SolicitadorRoot 'logs') -Force | Out-Null

$env:SOLICITADOR_ROOT = [IO.Path]::GetFullPath($SolicitadorRoot)
$env:SOLICITADOR_PLANILHA = [IO.Path]::GetFullPath($Planilha)
$env:SOLICITADOR_DRY_RUN = $dryRunValue
$env:BAILEYS_ENDPOINT = "http://127.0.0.1:$baileysPortValue/send"
$env:N8N_USER_FOLDER = [IO.Path]::GetFullPath($N8nUserFolder)
$env:N8N_PORT = "$port"
$env:N8N_HOST = 'localhost'
$env:N8N_PROTOCOL = 'http'
$env:WEBHOOK_URL = "http://localhost:$port/"
$env:TZ = $timeZoneValue
$env:GENERIC_TIMEZONE = $timeZoneValue
$env:NODE_FUNCTION_ALLOW_BUILTIN = 'fs,path,http'
$env:N8N_BLOCK_ENV_ACCESS_IN_NODE = 'false'
$env:N8N_RESTRICT_FILE_ACCESS_TO = $env:SOLICITADOR_ROOT

Write-Host "n8n: http://localhost:$port"
Write-Host "Planilha: $env:SOLICITADOR_PLANILHA"
Write-Host "Dry-run: $env:SOLICITADOR_DRY_RUN"
Write-Host 'Mantenha dry-run ativo durante os primeiros testes.'

& $n8nCommand.Source start
