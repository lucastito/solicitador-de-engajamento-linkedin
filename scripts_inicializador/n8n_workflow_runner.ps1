param(
  [Parameter(Mandatory = $true)][string]$WorkflowName,
  [string]$WorkflowId = '',
  [Parameter(Mandatory = $true)][string]$WorkflowSlug,
  [int]$Port = 15679,
  [string]$Timezone = 'America/Sao_Paulo',
  [switch]$ForceRestart,
  [switch]$OpenUi
)

$ErrorActionPreference = 'Stop'

$ScriptsDir = Split-Path -Path $PSCommandPath -Parent
$N8nRoot = Split-Path -Path $ScriptsDir -Parent
$N8nUserFolder = Join-Path $N8nRoot 'data'
$N8nDataDir = Join-Path $N8nUserFolder '.n8n'
$LogRoot = Join-Path $N8nRoot 'logs'
$RuntimeLogDir = Join-Path $LogRoot 'runtime'
$WorkflowLogDir = Join-Path $LogRoot $WorkflowSlug
$WorkflowRootDir = Join-Path $N8nRoot $WorkflowSlug
$WorkflowDataDir = Join-Path $WorkflowRootDir 'data'
$PidFile = Join-Path $N8nUserFolder 'n8n-native.pid'
$LogFile = Join-Path $RuntimeLogDir ($WorkflowSlug + '.log')
$N8nUrl = "http://localhost:$Port"

# --- Carregar caminhos de maquina de um .env (git-ignored), nunca hardcoded ---
# O .env fica na raiz do repositorio (pai de scripts_inicializador). Ver .env.example.
function Import-DotEnv {
  param([string]$Path)
  $result = @{}
  if (-not (Test-Path -LiteralPath $Path)) {
    return $result
  }
  foreach ($line in (Get-Content -LiteralPath $Path)) {
    $trimmed = $line.Trim()
    if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }
    $idx = $trimmed.IndexOf('=')
    if ($idx -lt 1) { continue }
    $key = $trimmed.Substring(0, $idx).Trim()
    $val = $trimmed.Substring($idx + 1).Trim().Trim('"').Trim("'")
    $result[$key] = $val
  }
  return $result
}

$EnvFile = Join-Path $N8nRoot '.env'
$DotEnv = Import-DotEnv -Path $EnvFile
if (-not $DotEnv.ContainsKey('DOWNLOADS_PATH') -or -not $DotEnv.ContainsKey('DRIVE_TARGET_PATH')) {
  throw "Arquivo .env ausente ou incompleto em $EnvFile. Copie .env.example para .env e preencha DOWNLOADS_PATH e DRIVE_TARGET_PATH."
}
$DownloadsPath = $DotEnv['DOWNLOADS_PATH']
$DriveTargetPath = $DotEnv['DRIVE_TARGET_PATH']

$LegacyConfigCandidates = @(
  'C:\Users\Lucas Tito\n8n-native-data\.n8n\config',
  'C:\Users\Lucas Tito\n8n-data\config',
  (Join-Path $env:USERPROFILE 'n8n-data\config')
)

function Write-Info {
  param([string]$Message)
  $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  $line = "[$stamp] $Message"
  Write-Host $line
  Add-Content -Path $LogFile -Value $line
}

function Ensure-Directory {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function Get-N8nCommandPath {
  $candidates = @(
    (Join-Path $env:APPDATA 'npm\n8n.cmd'),
    (Join-Path $env:USERPROFILE 'AppData\Roaming\npm\n8n.cmd')
  )

  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate) {
      return $candidate
    }
  }

  $cmd = Get-Command -Name 'n8n.cmd' -ErrorAction SilentlyContinue
  if ($null -ne $cmd) {
    return $cmd.Source
  }

  return $null
}

function Ensure-N8nInstalled {
  $n8nCmd = Get-N8nCommandPath
  if ($null -ne $n8nCmd) {
    return $n8nCmd
  }

  Write-Info 'n8n nao encontrado. Instalando n8n globalmente via npm...'
  $npmCmd = Get-Command -Name 'npm.cmd' -ErrorAction SilentlyContinue
  if ($null -eq $npmCmd) {
    throw 'npm.cmd nao encontrado. Instale Node.js LTS no Windows e execute novamente.'
  }

  $install = Start-Process -FilePath $npmCmd.Source -ArgumentList @('install', '-g', 'n8n@latest') -Wait -PassThru -NoNewWindow
  if ($install.ExitCode -ne 0) {
    throw "Falha ao instalar n8n (codigo $($install.ExitCode))."
  }

  $n8nCmd = Get-N8nCommandPath
  if ($null -eq $n8nCmd) {
    throw 'n8n foi instalado, mas n8n.cmd nao foi localizado no PATH esperado.'
  }

  Write-Info "n8n instalado em: $n8nCmd"
  return $n8nCmd
}

function Get-N8nEntryScriptPath {
  param([string]$N8nCmd)

  $npmBinDir = Split-Path -Path $N8nCmd -Parent
  $entryScript = Join-Path $npmBinDir 'node_modules\n8n\bin\n8n'
  if (-not (Test-Path -LiteralPath $entryScript)) {
    throw "Arquivo de entrada do n8n nao encontrado: $entryScript"
  }

  return $entryScript
}

function Set-N8nEnvironment {
  param([string]$UserFolder)

  $env:N8N_HOST = 'localhost'
  $env:N8N_PORT = "$Port"
  $env:N8N_PROTOCOL = 'http'
  $env:WEBHOOK_URL = "$N8nUrl/"
  $env:TZ = $Timezone
  $env:GENERIC_TIMEZONE = $Timezone
  $env:N8N_USER_FOLDER = $UserFolder
  $env:NODE_FUNCTION_ALLOW_BUILTIN = 'fs,path,http,https'
  $env:N8N_RESTRICT_FILE_ACCESS_TO = "$DownloadsPath;$DriveTargetPath;$WorkflowLogDir;$WorkflowDataDir;$WorkflowRootDir"
  $env:N8N_RUNNERS_HEARTBEAT_INTERVAL = '300'
  $env:N8N_RUNNERS_TASK_REQUEST_TIMEOUT = '600'
}

function Test-TrackedPaths {
  Ensure-Directory -Path $WorkflowRootDir
  Ensure-Directory -Path $WorkflowDataDir

  if ($WorkflowSlug -eq 'organizador_arquivos') {
    if (-not (Test-Path -LiteralPath $DownloadsPath)) {
      throw "Pasta de origem nao encontrada: $DownloadsPath"
    }

    if (-not (Test-Path -LiteralPath $DriveTargetPath)) {
      throw "Pasta de destino nao encontrada: $DriveTargetPath"
    }

    $probe = Join-Path $DriveTargetPath ('.n8n_write_probe_' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
      Set-Content -LiteralPath $probe -Value 'ok' -Encoding UTF8 -ErrorAction Stop
      Remove-Item -LiteralPath $probe -Force -ErrorAction Stop
    }
    catch {
      throw "Sem permissao de escrita em $DriveTargetPath. Detalhes: $($_.Exception.Message)"
    }
  }
}

function Ensure-NativeConfig {
  Ensure-Directory -Path $N8nDataDir

  $nativeConfigPath = Join-Path $N8nDataDir 'config'
  if (Test-Path -LiteralPath $nativeConfigPath) {
    return
  }

  foreach ($candidate in $LegacyConfigCandidates) {
    if (Test-Path -LiteralPath $candidate) {
      Copy-Item -LiteralPath $candidate -Destination $nativeConfigPath -Force
      Write-Info "Config de criptografia reaproveitada de: $candidate"
      return
    }
  }
}

function Get-WorkflowCount {
  param([string]$N8nCmd)

  $tempExport = Join-Path $env:TEMP ('n8n-workflows-' + [Guid]::NewGuid().ToString('N') + '.json')
  try {
    & $N8nCmd export:workflow --all --output=$tempExport | Out-Null
    if (-not (Test-Path -LiteralPath $tempExport)) {
      return 0
    }

    $content = Get-Content -LiteralPath $tempExport -Raw
    if ([string]::IsNullOrWhiteSpace($content)) {
      return 0
    }

    $parsed = $content | ConvertFrom-Json
    if ($parsed -is [System.Array]) {
      return $parsed.Count
    }

    if ($null -eq $parsed) {
      return 0
    }

    return 1
  }
  finally {
    if (Test-Path -LiteralPath $tempExport) {
      Remove-Item -LiteralPath $tempExport -Force -ErrorAction SilentlyContinue
    }
  }
}

function Resolve-LatestWorkflowBackup {
  $searchRoots = @(
    $N8nRoot,
    (Join-Path $env:USERPROFILE 'Documents\Backups\n8n'),
    $env:USERPROFILE
  )

  $candidates = @()
  foreach ($root in $searchRoots) {
    if (-not (Test-Path -LiteralPath $root)) {
      continue
    }

    $dirs = Get-ChildItem -Path $root -Directory -Filter 'n8n-migration-backup-*' -ErrorAction SilentlyContinue
    if ($dirs) {
      $candidates += $dirs
    }
  }

  if ($candidates.Count -eq 0) {
    return $null
  }

  $backupDir = $candidates | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  $workflowFile = Get-ChildItem -Path $backupDir.FullName -File -Filter 'workflows-export-*.json' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

  return $workflowFile
}

function Ensure-WorkflowImported {
  param([string]$N8nCmd)

  $count = Get-WorkflowCount -N8nCmd $N8nCmd
  Write-Info "Workflows atuais no n8n: $count"

  if ($count -gt 0) {
    return
  }

  $backupWorkflow = Resolve-LatestWorkflowBackup
  if ($null -eq $backupWorkflow) {
    Write-Info 'Nenhum backup de workflow encontrado para importacao automatica.'
    return
  }

  Write-Info "Importando workflow do backup: $($backupWorkflow.FullName)"
  & $N8nCmd import:workflow --input="$($backupWorkflow.FullName)" | Out-Null
  $newCount = Get-WorkflowCount -N8nCmd $N8nCmd
  Write-Info "Workflows apos importacao: $newCount"
}

function Resolve-WorkflowId {
  param(
    [string]$N8nCmd,
    [string]$PreferredId,
    [string]$PreferredName
  )

  $tempExport = Join-Path $env:TEMP ('n8n-workflows-' + [Guid]::NewGuid().ToString('N') + '.json')
  try {
    & $N8nCmd export:workflow --all --output=$tempExport | Out-Null
    if (-not (Test-Path -LiteralPath $tempExport)) {
      throw 'Nao foi possivel exportar workflows para localizar o ID.'
    }

    $content = Get-Content -LiteralPath $tempExport -Raw
    if ([string]::IsNullOrWhiteSpace($content)) {
      throw 'Nenhum workflow encontrado no n8n.'
    }

    $workflows = $content | ConvertFrom-Json
    if ($workflows -isnot [System.Array]) {
      $workflows = @($workflows)
    }

    if (-not [string]::IsNullOrWhiteSpace($PreferredId)) {
      $byId = @($workflows | Where-Object { $_.id -eq $PreferredId })
      if ($byId.Count -gt 0) {
        return $byId[0].id
      }
    }

    $byName = @($workflows | Where-Object { $_.name -eq $PreferredName })
    if ($byName.Count -gt 0) {
      return $byName[0].id
    }

    $names = ($workflows | ForEach-Object { $_.name + ' (' + $_.id + ')' }) -join '; '
    throw ("Workflow alvo nao encontrado. Disponiveis: " + $names)
  }
  finally {
    if (Test-Path -LiteralPath $tempExport) {
      Remove-Item -LiteralPath $tempExport -Force -ErrorAction SilentlyContinue
    }
  }
}

function Get-RunningN8nPid {
  if (Test-Path -LiteralPath $PidFile) {
    $raw = (Get-Content -LiteralPath $PidFile -Raw).Trim()
    if ($raw -match '^\d+$') {
      $storedPid = [int]$raw
      $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $storedPid" -ErrorAction SilentlyContinue
      if (($null -ne $proc) -and ($proc.CommandLine -match 'node_modules\\n8n\\bin\\n8n.*\sstart')) {
        return $storedPid
      }
    }

    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
  }

  $existing = Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'node_modules\\n8n\\bin\\n8n.*\sstart' } |
    Select-Object -First 1

  if ($null -eq $existing) {
    return $null
  }

  Set-Content -LiteralPath $PidFile -Value $existing.ProcessId -Encoding ASCII
  return [int]$existing.ProcessId
}

function Stop-N8nServerIfRunning {
  $runningPid = Get-RunningN8nPid
  if ($null -ne $runningPid) {
    Stop-Process -Id $runningPid -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    Write-Info "n8n server encerrado para execucao automatica (PID $runningPid)."
  }

  $taskRunnerProcs = @(Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match '@n8n\\task-runner' })
  foreach ($proc in $taskRunnerProcs) {
    Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
  }
}

function Start-N8nBackground {
  param([string]$N8nCmd)

  $stdoutPath = Join-Path $RuntimeLogDir 'n8n.out.log'
  $stderrPath = Join-Path $RuntimeLogDir 'n8n.err.log'
  $entryScript = Get-N8nEntryScriptPath -N8nCmd $N8nCmd
  $nodeCmd = Get-Command -Name 'node.exe' -ErrorAction SilentlyContinue
  if ($null -eq $nodeCmd) {
    throw 'node.exe nao encontrado no PATH.'
  }

  $escapedEntry = '"' + $entryScript + '"'
  $proc = Start-Process -FilePath $nodeCmd.Source -ArgumentList @($escapedEntry, 'start') -PassThru -WindowStyle Hidden -WorkingDirectory $N8nRoot -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath

  Start-Sleep -Milliseconds 600
  if ($proc.HasExited) {
    $errPreview = ''
    if (Test-Path -LiteralPath $stderrPath) {
      $errPreview = (Get-Content -LiteralPath $stderrPath -Tail 20 -ErrorAction SilentlyContinue) -join [Environment]::NewLine
    }

    throw ("n8n encerrou logo apos iniciar (exit code " + $proc.ExitCode + "). " + $errPreview)
  }

  Set-Content -LiteralPath $PidFile -Value $proc.Id -Encoding ASCII
  Write-Info "n8n iniciado em background (PID $($proc.Id))."
  return $proc.Id
}

function Wait-N8nHttp {
  for ($i = 1; $i -le 120; $i++) {
    try {
      $res = Invoke-WebRequest -UseBasicParsing -Uri $N8nUrl -TimeoutSec 5
      if ($res.StatusCode -ge 200 -and $res.StatusCode -lt 500) {
        Write-Info "n8n respondeu em $N8nUrl"
        return
      }
    }
    catch {
      Start-Sleep -Seconds 2
    }
  }

  throw "n8n nao respondeu em $N8nUrl dentro do tempo esperado."
}

function Get-FirefoxPath {
  $candidates = @(
    'C:\Program Files\Mozilla Firefox\firefox.exe',
    'C:\Program Files (x86)\Mozilla Firefox\firefox.exe',
    (Join-Path $env:LOCALAPPDATA 'Mozilla Firefox\firefox.exe')
  )

  foreach ($path in $candidates) {
    if (Test-Path -LiteralPath $path) {
      return $path
    }
  }

  return $null
}

function Open-N8nInFirefox {
  $firefoxPath = Get-FirefoxPath

  if ($null -eq $firefoxPath) {
    Write-Info 'Firefox nao encontrado. Abrindo URL no navegador padrao.'
    Start-Process $N8nUrl | Out-Null
    return
  }

  Start-Process -FilePath $firefoxPath -ArgumentList @('-new-tab', $N8nUrl) | Out-Null
  Write-Info 'n8n aberto no Firefox.'
}

function Execute-WorkflowNow {
  param(
    [string]$N8nCmd,
    [string]$TargetWorkflowId
  )

  Write-Info "Executando workflow automaticamente (ID $TargetWorkflowId)..."
  & $N8nCmd execute --id=$TargetWorkflowId --rawOutput | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Falha ao executar workflow automaticamente (exit code $LASTEXITCODE)."
  }

  Write-Info 'Workflow executado com sucesso.'
}

Ensure-Directory -Path $N8nRoot
Ensure-Directory -Path $LogRoot
Ensure-Directory -Path $RuntimeLogDir
Ensure-Directory -Path $WorkflowLogDir
Ensure-Directory -Path $WorkflowRootDir
Ensure-Directory -Path $WorkflowDataDir
Ensure-Directory -Path $N8nUserFolder
Write-Info "Iniciando automacao n8n para: $WorkflowSlug"

Test-TrackedPaths
if ($WorkflowSlug -eq 'organizador_arquivos') {
  Write-Info 'Validacao de Downloads e H:\ concluida com sucesso.'
} else {
  Write-Info "Validacao do diretorio do workflow concluida: $WorkflowDataDir"
}

$n8nCmd = Ensure-N8nInstalled
Set-N8nEnvironment -UserFolder $N8nUserFolder
Ensure-NativeConfig
Ensure-WorkflowImported -N8nCmd $n8nCmd

$resolvedWorkflowId = Resolve-WorkflowId -N8nCmd $n8nCmd -PreferredId $WorkflowId -PreferredName $WorkflowName

if ($ForceRestart) {
  Write-Info 'ForceRestart solicitado. Encerrando instancias antigas antes da execucao.'
}

Stop-N8nServerIfRunning
Execute-WorkflowNow -N8nCmd $n8nCmd -TargetWorkflowId $resolvedWorkflowId

if ($OpenUi) {
  [void](Start-N8nBackground -N8nCmd $n8nCmd)
  Wait-N8nHttp
  Open-N8nInFirefox
}

Write-Info 'Automacao concluida.'
