$SolicitadorRoot = $PSScriptRoot
$Planilha = Join-Path $SolicitadorRoot 'data\contatos_linkedin_envio.csv'
$N8nUserFolder = Join-Path $SolicitadorRoot '.n8n-data'
$N8nPort = 5679
$BaileysPort = 4010
$Timezone = 'America/Sao_Paulo'
$DryRun = $true
