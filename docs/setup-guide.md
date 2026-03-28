# 🔧 GUIA DEFINITIVO: Configuração do Cipher (Byterover) no WSL2

## Documento de Referência para Claude Code

**Objetivo:** Configurar o Cipher como memory layer persistente para coding agents, funcionando corretamente em ambiente WSL2, com dados sendo REALMENTE salvos e disponíveis para consulta.

**Contexto:** O usuário já tentou configurar com Qdrant (Docker Desktop) e ChromaDB, mas as informações NÃO estavam sendo salvas. Este documento contém TODA a informação necessária para uma configuração funcional.

---

## ⚠️ CAUSA RAIZ PROVÁVEL DOS PROBLEMAS ANTERIORES

### DESCOBERTA CRÍTICA (da documentação oficial no npmjs.com):

> **"When running MCP mode in terminal/shell, export all environment variables as Cipher won't read from .env file."**

Isso significa que quando o Cipher roda como MCP server (modo stdio), ele **NÃO lê o arquivo `.env`**. As variáveis de ambiente precisam ser passadas DIRETAMENTE na configuração do MCP server (no bloco `"env"` do JSON de configuração). Esta é quase certamente a razão pela qual os dados não estavam sendo salvos — o Cipher estava rodando sem saber onde/como conectar ao vector store.

### Outros problemas comuns que causam perda de dados:

1. **Qdrant no Docker Desktop com WSL2:** A documentação oficial do Qdrant alerta: _"Using Docker/WSL on Windows with mounts is known to have file system problems causing data loss."_
2. **ChromaDB ephemeral:** Se o container Docker do ChromaDB for iniciado sem volume persistente (`-v`), os dados são perdidos ao reiniciar.
3. **Falta de API key para embeddings:** Sem embeddings funcionando, as tools de memória são desabilitadas silenciosamente.
4. **`VECTOR_STORE_TYPE` não definido:** O padrão é `in-memory`, que perde tudo ao reiniciar.

---

## 📋 PRÉ-REQUISITOS NO WSL2

```bash
# Verificar versão do Node.js (requer v18+)
node --version

# Verificar npm
npm --version

# Se não tiver Node.js 18+, instalar via nvm:
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.0/install.sh | bash
source ~/.bashrc
nvm install 20
nvm use 20

# Docker deve estar funcionando DENTRO do WSL2 (não Docker Desktop do Windows)
# Verificar:
docker --version
docker ps
```

---

## 🚀 INSTALAÇÃO DO CIPHER

### Método Recomendado: NPM Global

```bash
npm install -g @byterover/cipher

# Verificar instalação
cipher --version
which cipher
```

### Método Alternativo: From Source

```bash
cd ~
git clone https://github.com/campfirein/cipher.git
cd cipher
npm install -g pnpm  # se não tiver
pnpm i && pnpm run build && npm link

# Verificar
cipher --version
```

---

## 🗄️ CONFIGURAÇÃO DO VECTOR STORE (Qdrant no WSL2)

### Por que Qdrant dentro do WSL2 (e NÃO Docker Desktop)?

- A documentação do Qdrant alerta sobre perda de dados com Docker Desktop + WSL mounts
- Rodar o Qdrant via Docker DENTRO do WSL2 evita esse problema
- É a opção mais estável e documentada para o Cipher

### Iniciar Qdrant com persistência NO WSL2:

```bash
# Criar diretório para persistência
mkdir -p ~/qdrant_storage

# Rodar Qdrant com volume persistente DENTRO do WSL2
docker run -d \
  --name qdrant \
  --restart unless-stopped \
  -p 6333:6333 \
  -p 6334:6334 \
  -v ~/qdrant_storage:/qdrant/storage:z \
  qdrant/qdrant

# Verificar se está rodando
docker ps | grep qdrant

# Testar conectividade
curl http://localhost:6333/healthz
# Deve retornar algo como: {"title":"qdrant..."}

# Ver collections existentes (deve estar vazio inicialmente)
curl http://localhost:6333/collections
```

### VERIFICAÇÃO OBRIGATÓRIA - Qdrant respondendo:

```bash
# Este comando DEVE retornar um JSON válido
curl -s http://localhost:6333/collections | head -20

# Se não retornar, o Qdrant não está rodando corretamente
# Debug:
docker logs qdrant
```

---

## ⚙️ CONFIGURAÇÃO DO CIPHER

### Arquivo: `memAgent/cipher.yml`

Este arquivo fica no diretório onde o Cipher é executado. Para uso global, crie em `~/.cipher/` ou no diretório do projeto.

```yaml
# memAgent/cipher.yml
# Configuração do LLM - usar Anthropic (Claude) como provider
llm:
  provider: anthropic
  model: claude-sonnet-4-20250514
  apiKey: $ANTHROPIC_API_KEY
  maxIterations: 50

# Embedding - usar OpenAI para embeddings (mais estável)
# Cipher com Anthropic faz fallback para Voyage embeddings
# Se não tiver VOYAGE_API_KEY, usar OpenAI para embeddings
embedding:
  type: openai
  model: text-embedding-3-small
  apiKey: $OPENAI_API_KEY

# System Prompt customizado
systemPrompt:
  enabled: true
  content: |
    You are an AI programming assistant with persistent memory capabilities.
    Always store important decisions, patterns, and solutions.
    Always retrieve relevant context before starting tasks.

# MCP Servers adicionais (opcional)
mcpServers: {}
```

**NOTA IMPORTANTE sobre Embeddings:**

- Se usar `provider: anthropic` no LLM, o Cipher tenta usar Voyage para embeddings (requer `VOYAGE_API_KEY`)
- A alternativa mais simples é configurar embeddings explicitamente com OpenAI (`text-embedding-3-small`)
- O `VECTOR_STORE_DIMENSION` deve ser `1536` para `text-embedding-3-small` do OpenAI
- Se usar Voyage `voyage-3-large`, o dimension deve ser `1024`

### Arquivo: `.env` (para modo CLI — NÃO lido em modo MCP!)

Crie este arquivo no diretório raiz do projeto ou em `~/`:

```bash
# ======================
# API Keys (necessário pelo menos uma para LLM + uma para embeddings)
# ======================
ANTHROPIC_API_KEY=sk-ant-XXXXXXX
OPENAI_API_KEY=sk-XXXXXXX

# ======================
# Vector Store - Qdrant LOCAL no WSL2
# ======================
VECTOR_STORE_TYPE=qdrant
VECTOR_STORE_HOST=localhost
VECTOR_STORE_PORT=6333
VECTOR_STORE_URL=http://localhost:6333

# ======================
# Memory Settings
# ======================
VECTOR_STORE_COLLECTION=knowledge_memory
VECTOR_STORE_DIMENSION=1536
VECTOR_STORE_DISTANCE=Cosine
VECTOR_STORE_MAX_VECTORS=10000

# Reflection memory (opcional, desabilitado por padrão)
REFLECTION_VECTOR_STORE_COLLECTION=reflection_memory
DISABLE_REFLECTION_MEMORY=false

# Workspace memory (para compartilhar entre agentes/projetos)
USE_WORKSPACE_MEMORY=true
WORKSPACE_VECTOR_STORE_COLLECTION=workspace_memory
```

---

## 🔌 INTEGRAÇÃO COM CLAUDE CODE (A PARTE MAIS IMPORTANTE)

### ⚡ POR QUE ESTA SEÇÃO É CRÍTICA:

Em modo MCP (stdio), o Cipher **NÃO LÊ o arquivo `.env`**. TODAS as variáveis de ambiente devem ser passadas no bloco `"env"` da configuração MCP. Se você não fizer isso, o Cipher roda com defaults (in-memory) e PERDE todos os dados.

### Método 1: Via `claude mcp add-json` (Recomendado)

```bash
claude mcp add-json "cipher" '{
  "type": "stdio",
  "command": "cipher",
  "args": ["--mode", "mcp"],
  "env": {
    "MCP_SERVER_MODE": "aggregator",
    "ANTHROPIC_API_KEY": "sk-ant-COLOQUE_SUA_KEY_AQUI",
    "OPENAI_API_KEY": "sk-COLOQUE_SUA_KEY_AQUI",
    "VECTOR_STORE_TYPE": "qdrant",
    "VECTOR_STORE_HOST": "localhost",
    "VECTOR_STORE_PORT": "6333",
    "VECTOR_STORE_URL": "http://localhost:6333",
    "VECTOR_STORE_COLLECTION": "knowledge_memory",
    "VECTOR_STORE_DIMENSION": "1536",
    "VECTOR_STORE_DISTANCE": "Cosine",
    "USE_WORKSPACE_MEMORY": "true",
    "WORKSPACE_VECTOR_STORE_COLLECTION": "workspace_memory",
    "DISABLE_REFLECTION_MEMORY": "false",
    "REFLECTION_VECTOR_STORE_COLLECTION": "reflection_memory"
  }
}' --scope user
```

**O flag `--scope user` torna o MCP disponível em TODOS os projetos do usuário.**

### Método 2: Via arquivo de configuração direto

Edite o arquivo `~/.claude.json` (ou `~/.claude/settings.json` dependendo da versão):

```json
{
  "mcpServers": {
    "cipher": {
      "type": "stdio",
      "command": "cipher",
      "args": ["--mode", "mcp"],
      "env": {
        "MCP_SERVER_MODE": "aggregator",
        "ANTHROPIC_API_KEY": "sk-ant-COLOQUE_SUA_KEY_AQUI",
        "OPENAI_API_KEY": "sk-COLOQUE_SUA_KEY_AQUI",
        "VECTOR_STORE_TYPE": "qdrant",
        "VECTOR_STORE_HOST": "localhost",
        "VECTOR_STORE_PORT": "6333",
        "VECTOR_STORE_URL": "http://localhost:6333",
        "VECTOR_STORE_COLLECTION": "knowledge_memory",
        "VECTOR_STORE_DIMENSION": "1536",
        "VECTOR_STORE_DISTANCE": "Cosine",
        "USE_WORKSPACE_MEMORY": "true",
        "WORKSPACE_VECTOR_STORE_COLLECTION": "workspace_memory",
        "DISABLE_REFLECTION_MEMORY": "false",
        "REFLECTION_VECTOR_STORE_COLLECTION": "reflection_memory"
      }
    }
  }
}
```

### Método 3: Via `.mcp.json` no projeto (scope local)

Crie um arquivo `.mcp.json` na raiz de qualquer projeto:

```json
{
  "mcpServers": {
    "cipher": {
      "type": "stdio",
      "command": "cipher",
      "args": ["--mode", "mcp"],
      "env": {
        "MCP_SERVER_MODE": "aggregator",
        "ANTHROPIC_API_KEY": "sk-ant-COLOQUE_SUA_KEY_AQUI",
        "OPENAI_API_KEY": "sk-COLOQUE_SUA_KEY_AQUI",
        "VECTOR_STORE_TYPE": "qdrant",
        "VECTOR_STORE_HOST": "localhost",
        "VECTOR_STORE_PORT": "6333",
        "VECTOR_STORE_URL": "http://localhost:6333",
        "VECTOR_STORE_COLLECTION": "knowledge_memory",
        "VECTOR_STORE_DIMENSION": "1536",
        "VECTOR_STORE_DISTANCE": "Cosine",
        "USE_WORKSPACE_MEMORY": "true",
        "WORKSPACE_VECTOR_STORE_COLLECTION": "workspace_memory",
        "DISABLE_REFLECTION_MEMORY": "false",
        "REFLECTION_VECTOR_STORE_COLLECTION": "reflection_memory"
      }
    }
  }
}
```

---

## ✅ VERIFICAÇÃO PÓS-CONFIGURAÇÃO

### Passo 1: Verificar Qdrant rodando

```bash
curl -s http://localhost:6333/collections
```

### Passo 2: Iniciar Claude Code e verificar MCP

```bash
claude
# Dentro do Claude Code:
/mcp
# cipher deve aparecer como "connected"
```

### Passo 3: Teste de gravação de memória

Dentro do Claude Code, peça:

```
Store this in Cipher memory: "Our tech stack uses n8n for automations, Python with LangChain/LangGraph for AI agents, and Next.js with Builder.io for frontend. Company name is Integrare Tecnologia."
```

### Passo 4: Verificar se foi salvo no Qdrant

```bash
# Verificar se collections foram criadas no Qdrant
curl -s http://localhost:6333/collections | python3 -m json.tool

# Deve mostrar collections como:
# - knowledge_memory
# - workspace_memory
# - reflection_memory (se habilitado)
```

### Passo 5: Teste de recuperação de memória

Abra uma NOVA sessão do Claude Code e pergunte:

```
Search your Cipher memory for our tech stack. What technologies do we use?
```

Se retornar a informação que foi salva, a configuração está **FUNCIONANDO CORRETAMENTE**.

---

## 🔍 TROUBLESHOOTING

### Problema: "Cannot perform memory search for current session"

**Causa:** Autenticação falhou ou variáveis de ambiente não foram passadas.
**Solução:** Verificar se TODAS as env vars estão no bloco `"env"` do MCP config (não no .env).

### Problema: Cipher conecta mas não salva dados

**Causa provável:** `VECTOR_STORE_TYPE` não está definido nas env vars do MCP.
**Solução:** Confirmar que `VECTOR_STORE_TYPE=qdrant` está no bloco `"env"`.

### Problema: Embeddings falhando

**Causa:** API key do provider de embeddings ausente.
**Solução:** Se usar embeddings OpenAI, garantir que `OPENAI_API_KEY` está no bloco `"env"`.
Se usar Anthropic como LLM, precisa de `VOYAGE_API_KEY` OU configurar embeddings OpenAI explicitamente.

### Problema: Qdrant não acessível

```bash
# Verificar se container está rodando
docker ps | grep qdrant

# Se não estiver, reiniciar
docker start qdrant

# Verificar logs de erro
docker logs qdrant --tail 50

# Testar conectividade
curl http://localhost:6333/healthz
```

### Problema: Dimension mismatch

**Causa:** O `VECTOR_STORE_DIMENSION` não corresponde ao modelo de embedding usado.
**Solução:**

- OpenAI `text-embedding-3-small` → dimension = `1536`
- OpenAI `text-embedding-3-large` → dimension = `3072`
- Voyage `voyage-3-large` → dimension = `1024`

### Verificar tudo de uma vez:

```bash
#!/bin/bash
echo "=== Qdrant Status ==="
curl -s http://localhost:6333/healthz && echo " ✅ Qdrant OK" || echo " ❌ Qdrant DOWN"

echo ""
echo "=== Qdrant Collections ==="
curl -s http://localhost:6333/collections | python3 -m json.tool 2>/dev/null || echo "❌ Nenhuma collection encontrada"

echo ""
echo "=== Cipher Instalado ==="
which cipher && cipher --version || echo "❌ Cipher não encontrado"

echo ""
echo "=== Claude Code MCP ==="
claude mcp list 2>/dev/null | grep cipher || echo "⚠️  Cipher MCP não encontrado no Claude Code"
```

---

## 📚 FERRAMENTAS (TOOLS) DO CIPHER DISPONÍVEIS VIA MCP

Quando configurado corretamente, o Cipher expõe estas tools para os agentes:

### Memory Tools:

- **`cipher_memory_search`** — Busca semântica na memória (knowledge memory)
- **`cipher_extract_and_operate_memory`** — Extrai e opera sobre memórias (adicionar/atualizar/deletar)
- **`ask_cipher`** — Perguntar ao Cipher (requer LLM configurado)

### Knowledge Graph Tools:

- **`cipher_extract_entities`** — Extrair entidades de texto
- **`cipher_update_node`** — Atualizar nós no grafo
- **`cipher_delete_node`** — Remover nós
- **`cipher_query_graph`** — Queries customizadas no grafo
- **`cipher_enhanced_search`** — Busca avançada com fuzzy matching
- **`cipher_intelligent_processor`** — Processamento de linguagem natural para entidades
- **`cipher_relationship_manager`** — Gerenciamento de relacionamentos

### System Tools:

- Ferramentas de bash, filesystem, etc. (se configuradas no cipher.yml como mcpServers)

---

## 🏗️ ARQUITETURA DE MEMÓRIA DO CIPHER

O Cipher implementa 3 camadas de memória:

1. **System 1 (Knowledge Memory):** Armazena fatos, conceitos, padrões de código, lógica de negócio, interações passadas. Usa vector embeddings para busca semântica. Collection: `knowledge_memory`

2. **System 2 (Reflection Memory):** Captura os passos de raciocínio do modelo durante geração de código. Permite aprendizado contínuo. Collection: `reflection_memory`

3. **Workspace Memory:** Memória compartilhada entre equipe/agentes. Permite que diferentes agentes/IDEs acessem o mesmo contexto. Collection: `workspace_memory`

---

## 💡 DICAS PARA USO EFETIVO

1. **Sempre que resolver um bug complexo**, peça ao agente para salvar no Cipher
2. **Armazene padrões de arquitetura** do projeto para consulta futura
3. **Salve decisões de design** para manter consistência entre sessões
4. **Use workspace memory** para compartilhar entre Claude Code e outros agentes
5. **Verifique periodicamente** as collections no Qdrant para confirmar que dados estão sendo persistidos

---

## 📎 REFERÊNCIAS

- **GitHub:** https://github.com/campfirein/cipher
- **Documentação oficial:** https://docs.byterover.dev/cipher/overview
- **Quickstart:** https://docs.byterover.dev/cipher/quickstart
- **NPM:** https://www.npmjs.com/package/@byterover/cipher
- **Memory Overview:** https://docs.byterover.dev/cipher/memory-overview
