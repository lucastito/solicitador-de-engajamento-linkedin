param(
  [int]$Port = 15680,
  [string]$Timezone = 'America/Sao_Paulo',
  [switch]$ForceRestart,
  [switch]$OpenUi,
  [switch]$SkipBaileysCheck,
  [string]$WorkflowId = 'r9JxkPq4sLd2Vt8N',
  [string]$WorkflowName = 'solicitador_de_engajamento_linkedin'
)

$ErrorActionPreference = 'Stop'

$N8nRoot = Split-Path -Path $PSScriptRoot -Parent
$BridgeDir = Join-Path $N8nRoot 'baileys_bridge'
$BridgeSessionDir = Join-Path $BridgeDir 'session'
$BridgeHealthUrl = 'http://127.0.0.1:4010/health'
$BridgeProcessPattern = 'baileys_bridge\\server.js'

function Get-BridgeHealth {
  try {
    return Invoke-RestMethod -Uri $BridgeHealthUrl -TimeoutSec 4 -Method Get
  }
  catch {
    return $null
  }
}

function Get-BridgeProcesses {
  return @(Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match $BridgeProcessPattern })
}

function Stop-BridgeProcesses {
  $procs = Get-BridgeProcesses
  foreach ($proc in $procs) {
    Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
  }
}

function Start-BridgeProcess {
  param([bool]$Visible)

  $command = "Set-Location -LiteralPath '$BridgeDir'; npm.cmd start"
  $args = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass')

  if ($Visible) {
    $args += @('-NoExit', '-Command', $command)
    Start-Process -FilePath powershell.exe -ArgumentList $args | Out-Null
  }
  else {
    $args += @('-Command', $command)
    Start-Process -FilePath powershell.exe -ArgumentList $args -WindowStyle Hidden | Out-Null
  }
}

function Ensure-BridgeDependencies {
  $depPath = Join-Path $BridgeDir 'node_modules\@whiskeysockets\baileys'
  if (Test-Path -LiteralPath $depPath) {
    return
  }

  Write-Output '[solicitador] Instalando dependencias do Baileys bridge...'
  $npmCmd = Get-Command -Name 'npm.cmd' -ErrorAction SilentlyContinue
  if ($null -eq $npmCmd) {
    throw 'npm.cmd nao encontrado. Instale Node.js para usar Baileys bridge.'
  }

  $install = Start-Process -FilePath $npmCmd.Source -ArgumentList @('install') -Wait -PassThru -NoNewWindow -WorkingDirectory $BridgeDir
  if ($install.ExitCode -ne 0) {
    throw "Falha no npm install do Baileys bridge (exit code $($install.ExitCode))."
  }
}

function Wait-BridgeOnline {
  param([int]$TimeoutSeconds = 60)

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    $health = Get-BridgeHealth
    if ($null -ne $health -and $health.ok) {
      return $health
    }
    Start-Sleep -Seconds 2
  } while ((Get-Date) -lt $deadline)

  return $null
}

function Wait-BridgeConnected {
  param([int]$TimeoutSeconds = 180)

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    $health = Get-BridgeHealth
    if ($null -ne $health -and $health.ok -and $health.connected) {
      return $health
    }
    Start-Sleep -Seconds 2
  } while ((Get-Date) -lt $deadline)

  return $null
}

function Ensure-BaileysBridge {
  if (-not (Test-Path -LiteralPath $BridgeDir)) {
    throw "Diretorio do Baileys bridge nao encontrado: $BridgeDir"
  }

  if (-not (Test-Path -LiteralPath $BridgeSessionDir)) {
    New-Item -ItemType Directory -Path $BridgeSessionDir -Force | Out-Null
  }

  Ensure-BridgeDependencies

  if ($ForceRestart) {
    Write-Output '[solicitador] ForceRestart habilitado. Reiniciando Baileys bridge...'
    Stop-BridgeProcesses
    Start-Sleep -Seconds 1
  }

  $health = Get-BridgeHealth
  if ($null -ne $health -and $health.ok -and $health.connected) {
    Write-Output '[solicitador] Baileys bridge ja conectado.'
    return
  }

  $hasSessionFiles = @(Get-ChildItem -LiteralPath $BridgeSessionDir -File -ErrorAction SilentlyContinue).Count -gt 0

  if ($null -eq $health -or -not $health.ok) {
    Write-Output '[solicitador] Baileys bridge offline. Iniciando processo...'
    Start-BridgeProcess -Visible:$true

    $health = Wait-BridgeOnline -TimeoutSeconds 60
    if ($null -eq $health) {
      throw 'Baileys bridge nao subiu na porta 4010 dentro do tempo esperado.'
    }
  }

  if (-not $health.connected) {
    Write-Output '[solicitador] Baileys bridge ainda sem conexao. Reiniciando em janela visivel para exibir QR...'
    Stop-BridgeProcesses
    Start-Sleep -Seconds 1
    Start-BridgeProcess -Visible:$true
    $health = Wait-BridgeOnline -TimeoutSeconds 60
    if ($null -eq $health) {
      throw 'Baileys bridge nao subiu na porta 4010 apos reinicio visivel.'
    }
  }

  if (-not $health.connected -and -not $hasSessionFiles) {
    Write-Output '[solicitador] Primeira conexao detectada. Escaneie o QR na janela do Baileys bridge.'
  }

  if (-not $health.connected) {
    $connectedHealth = Wait-BridgeConnected -TimeoutSeconds 180
    if ($null -eq $connectedHealth) {
      throw 'Baileys bridge ainda nao conectado ao WhatsApp. Escaneie o QR e rode novamente.'
    }
  }

  Write-Output '[solicitador] Baileys bridge pronto.'
}

if (-not $SkipBaileysCheck) {
  Ensure-BaileysBridge
} else {
  Write-Output '[solicitador] SkipBaileysCheck habilitado para teste controlado.'
}

$runner = Join-Path $PSScriptRoot 'n8n_workflow_runner.ps1'
& $runner `
  -WorkflowName $WorkflowName `
  -WorkflowId $WorkflowId `
  -WorkflowSlug 'solicitador_engajamento_linkedin' `
  -Port $Port `
  -Timezone $Timezone `
  -ForceRestart:$ForceRestart `
  -OpenUi:$OpenUi
