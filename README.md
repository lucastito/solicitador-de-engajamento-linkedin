# Automação de planilha para WhatsApp com n8n

Projeto que lê contatos de uma planilha CSV, agrupa as linhas por publicação,
envia mensagens personalizadas pelo WhatsApp e atualiza o status de cada
tentativa. A orquestração usa n8n e o envio local usa uma ponte baseada em
Baileys.

## Funcionamento

1. O workflow lê o CSV configurado.
2. Identifica contatos pendentes e valida os campos obrigatórios.
3. Agrupa os contatos por publicação.
4. Envia a mensagem e o link pelo serviço local Baileys.
5. Atualiza o status e o detalhe do último envio.
6. Cria backup antes de alterar a planilha.
7. Registra tentativas e um resumo em JSON Lines.

O modo `dry-run` vem ativo por padrão. Nesse modo, o processamento é simulado
sem enviar mensagens reais.

## Conteúdo público

- `workflows/automacao-whatsapp-planilha.json`: workflow importável.
- `src/processar-planilha.js`: código principal em formato legível.
- `baileys_bridge/server.js`: serviço HTTP local para envio.
- `baileys_bridge/package.json`: dependências da ponte.
- `data/contatos.template.csv`: modelo fictício da planilha.
- `config.example.ps1`: configuração local de exemplo.
- `scripts/`: importação e inicialização dos componentes.

## Dados que não entram no Git

O `.gitignore` preserva localmente e impede a publicação de:

- sessão autenticada do WhatsApp;
- QR Code de pareamento;
- planilha real de contatos;
- backups da planilha;
- logs de envio;
- dados internos do n8n;
- dependências instaladas em `node_modules`.

Esses arquivos não precisam ser apagados para usar o Git.

## Requisitos

- Windows PowerShell 5.1 ou PowerShell 7.
- Node.js.
- n8n instalado globalmente:

```powershell
npm install -g n8n
```

## Configuração

```powershell
Copy-Item .\config.example.ps1 .\config.local.ps1
Copy-Item .\data\contatos.template.csv .\data\contatos_linkedin_envio.csv
```

Edite `config.local.ps1` e a planilha local. O arquivo de configuração e a
planilha preenchida são ignorados pelo Git.

Campos esperados:

- `nome da publicacao`
- `link da publicacao`
- `status de envio`
- `mensagem pro contato`
- `onde conheco`
- `nome da pessoa`
- `apelido`
- `numero de whats app`
- `detalhe do ultimo envio`

## Instalação e auditoria

```powershell
cd .\baileys_bridge
npm ci
npm test
npm run audit
cd ..
```

## Importar o workflow

```powershell
.\scripts\importar-workflow.ps1
```

## Executar

Em um terminal:

```powershell
.\scripts\iniciar-bridge.ps1
```

Na primeira execução, faça o pareamento pelo QR exibido no terminal.

Em outro terminal:

```powershell
.\scripts\iniciar-n8n.ps1
```

Abra o endereço exibido e execute manualmente
`automacao-whatsapp-planilha`. Mantenha `$DryRun = $true` até validar a
planilha e as mensagens.

## Avisos

- Use apenas com contatos que autorizaram comunicações.
- Respeite os termos do WhatsApp e a legislação aplicável.
- A biblioteca Baileys não é uma API oficial do WhatsApp.
- Faça backup da planilha antes de qualquer envio real.

## Licença

Distribuído sob a licença MIT.
