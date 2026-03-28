# Relatorio: Configuracao Definitiva do Cipher no WSL2

**Data:** 25/02/2026
**Executado por:** Claude Code (Opus 4.6)
**Solicitante:** Thiago (Integrare Tecnologia)

---

## 1. PROBLEMA ORIGINAL

O Cipher (Byterover) nao estava salvando memorias de forma persistente. Duas tentativas anteriores falharam:

1. **Qdrant via Docker Desktop:** Falhou porque Docker Desktop com WSL2 mounts tem problemas documentados de perda de dados no filesystem
2. **ChromaDB sem Docker:** Falhou pelo mesmo motivo raiz (detalhado abaixo)

### Causa raiz identificada (tripla):

| #   | Causa                                                                                                          | Impacto                                                     |
| --- | -------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------- |
| 1   | **Qdrant nao estava rodando** - Docker nao disponivel no WSL2                                                  | Cipher fazia fallback para in-memory, perdia tudo ao fechar |
| 2   | **`.env` nao e lido em modo MCP** - Documentacao oficial npm: "Cipher won't read from .env file" em modo stdio | Todas as variaveis de ambiente eram ignoradas               |
| 3   | **Path do Node desatualizado** - MCP apontava para Node v20.20.0 mas a versao ativa era v22.22.0               | Risco de incompatibilidade                                  |

---

## 2. O QUE FOI INSTALADO

### Qdrant v1.17.0 (binario nativo - SEM Docker)

| Item       | Valor                            |
| ---------- | -------------------------------- |
| Binario    | `/home/thiag/qdrant/qdrant`      |
| Config     | `/home/thiag/qdrant/config.yaml` |
| Storage    | `/home/thiag/qdrant/storage/`    |
| Snapshots  | `/home/thiag/qdrant/snapshots/`  |
| Porta HTTP | 6333                             |
| Porta gRPC | 6334                             |
| Bind       | 127.0.0.1 (apenas local)         |
| RAM em uso | ~164 MB (estavel com 4 vetores)  |

**Fonte do binario:** `https://github.com/qdrant/qdrant/releases/download/v1.17.0/qdrant-x86_64-unknown-linux-gnu.tar.gz`

---

## 3. O QUE FOI CONFIGURADO

### 3.1 Servico systemd (auto-start)

**Arquivo:** `/home/thiag/.config/systemd/user/qdrant.service`

```ini
[Unit]
Description=Qdrant Vector Database for Cipher Memory
After=network.target

[Service]
Type=simple
ExecStart=/home/thiag/qdrant/qdrant --config-path /home/thiag/qdrant/config.yaml
WorkingDirectory=/home/thiag/qdrant
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
```

- **Status:** enabled (inicia automaticamente com WSL2)
- **Linger:** yes (servico persiste apos logout)
- **WSL2:** `systemd=true` confirmado em `/etc/wsl.conf`

### 3.2 Qdrant config

**Arquivo:** `/home/thiag/qdrant/config.yaml`

```yaml
log_level: INFO
storage:
  storage_path: /home/thiag/qdrant/storage
  snapshots_path: /home/thiag/qdrant/snapshots
  optimizers:
    default_segment_number: 2
    indexing_threshold_kb: 20000
service:
  host: 127.0.0.1
  grpc_port: 6334
  http_port: 6333
  enable_cors: true
```

### 3.3 Cipher MCP (Claude Code)

**Arquivo:** `~/.claude.json` > `mcpServers.cipher`

```json
{
  "type": "stdio",
  "command": "/home/thiag/.nvm/versions/node/v22.22.0/bin/node",
  "args": [
    "/home/thiag/.nvm/versions/node/v22.22.0/lib/node_modules/@byterover/cipher/dist/src/app/index.cjs",
    "--agent",
    "/home/thiag/.cipher/cipher-zai.yml",
    "--mode",
    "mcp"
  ],
  "env": {
    "MCP_SERVER_MODE": "aggregator",
    "VECTOR_STORE_TYPE": "qdrant",
    "VECTOR_STORE_URL": "http://localhost:6333",
    "VECTOR_STORE_HOST": "localhost",
    "VECTOR_STORE_PORT": "6333",
    "VECTOR_STORE_COLLECTION": "cipher_memory",
    "VECTOR_STORE_DIMENSION": "1536",
    "VECTOR_STORE_DISTANCE": "Cosine",
    "STORAGE_DATABASE_TYPE": "sqlite",
    "STORAGE_DATABASE_PATH": "/home/thiag/.cipher/data",
    "STORAGE_DATABASE_NAME": "cipher.db",
    "SEARCH_MEMORY_TYPE": "both",
    "DISABLE_REFLECTION_MEMORY": "false",
    "USE_WORKSPACE_MEMORY": "true",
    "WORKSPACE_VECTOR_STORE_COLLECTION": "workspace_memory",
    "REFLECTION_VECTOR_STORE_COLLECTION": "reflection_memory",
    "ZAI_API_KEY": "***",
    "OPENAI_API_KEY": "***"
  }
}
```

**Escopo:** Global (user-level, aplica a TODOS os projetos)

### 3.4 Cipher config (LLM + Embeddings)

**Arquivo:** `/home/thiag/.cipher/cipher-zai.yml`

- LLM: OpenAI GPT-4o
- Embeddings: OpenAI text-embedding-3-small (dimensao 1536)

### 3.5 Arquivo .env atualizado

**Arquivo:** `/home/thiag/.cipher/.env`

- Adicionado aviso de que NAO e lido em modo MCP
- Adicionadas variaveis faltantes (HOST, PORT, DISTANCE, collection names)
- Serve apenas para uso CLI direto do Cipher

### 3.6 CLAUDE.md global

**Arquivo:** `/home/thiag/.claude/CLAUDE.md`

Instrui todos os agentes a:

- Buscar contexto no Cipher antes de tarefas complexas
- Salvar decisoes/padroes/solucoes apos tarefas bem-sucedidas
- Lista as tools disponiveis e quando usar cada uma

---

## 4. O QUE FOI CORRIGIDO

| Item                    | Antes                                       | Depois                                   |
| ----------------------- | ------------------------------------------- | ---------------------------------------- |
| Node path no MCP        | `v20.20.0` (desatualizado)                  | `v22.22.0` (versao ativa)                |
| Env vars no MCP         | Faltavam HOST, PORT, DISTANCE, collections  | Todas presentes                          |
| Config projeto agent-os | Cipher MCP com `"env": {}` (causaria falha) | **Removida** (usa global)                |
| Log do Qdrant           | Erros antigos de porta ocupada              | Limpo, sem erros                         |
| Script verify-cipher.sh | Nao mostrava collections                    | Mostra collections + contagem de vetores |

---

## 5. COLLECTIONS NO QDRANT

| Collection          | Tipo      | Vetores | Proposito                                     |
| ------------------- | --------- | ------- | --------------------------------------------- |
| `cipher_memory`     | Knowledge | 3       | Fatos, padroes, decisoes tecnicas             |
| `workspace_memory`  | Workspace | 1       | Progresso de projetos, bugs, colaboracao      |
| `reflection_memory` | Reasoning | 1       | Traces de raciocinio, avaliacoes de qualidade |

Todas com: dimensao 1536, distancia Cosine, on_disk_payload true.

---

## 6. RESULTADOS DOS TESTES

### Bateria completa: 17 PASS, 0 FAIL, 1 corrigido

| #   | Teste                                | Resultado                     |
| --- | ------------------------------------ | ----------------------------- |
| 1   | Knowledge Memory SAVE                | PASS                          |
| 2   | Knowledge Memory SEARCH              | PASS (sim 0.540)              |
| 3   | Workspace Memory SAVE                | PASS                          |
| 4   | Workspace Memory SEARCH              | PASS (sim 0.549)              |
| 5   | Reasoning Memory SAVE                | PASS                          |
| 6   | Reasoning Memory SEARCH              | PASS (score 0.508)            |
| 7   | Multiplas memorias + ranking         | PASS (2 resultados ordenados) |
| 8   | Contagem antes do restart            | PASS (4 vetores)              |
| 9   | **Persistencia apos restart Qdrant** | **PASS** (4 vetores intactos) |
| 10  | **Busca semantica pos-restart**      | **PASS** (3 camadas OK)       |
| 11  | Dados reais no disco                 | PASS (664K em storage/)       |
| 12  | WSL2 systemd=true                    | PASS                          |
| 13  | User Linger=yes                      | PASS                          |
| 14  | Log sem erros recentes               | PASS                          |
| 15  | Config conflitante agent-os          | CORRIGIDO e removida          |
| 16  | Nenhum .mcp.json conflitante         | PASS                          |
| 17  | Nenhuma ref ao Node v20              | PASS                          |
| 18  | OpenAI API key + dim 1536            | PASS                          |
| 19  | Permissoes de arquivos               | PASS                          |
| 20  | Script verify-cipher.sh              | PASS (mostra tudo)            |

---

## 7. ARQUIVOS CRIADOS/MODIFICADOS

### Criados:

| Arquivo                                           | Proposito                       |
| ------------------------------------------------- | ------------------------------- |
| `/home/thiag/qdrant/qdrant`                       | Binario Qdrant v1.17.0          |
| `/home/thiag/qdrant/config.yaml`                  | Config do Qdrant                |
| `/home/thiag/qdrant/storage/`                     | Diretorio de persistencia       |
| `/home/thiag/qdrant/snapshots/`                   | Diretorio de snapshots          |
| `/home/thiag/.config/systemd/user/qdrant.service` | Servico auto-start              |
| `/home/thiag/.claude/CLAUDE.md`                   | Instrucoes globais para agentes |
| `/home/thiag/.cipher/verify-cipher.sh`            | Script de diagnostico           |

### Modificados:

| Arquivo                              | Alteracao                                |
| ------------------------------------ | ---------------------------------------- |
| `~/.claude.json` (mcpServers.cipher) | Node path v20->v22, env vars adicionadas |
| `~/.claude.json` (projects.agent-os) | Removida config cipher com env vazio     |
| `/home/thiag/.cipher/.env`           | Adicionado aviso MCP, vars faltantes     |

---

## 8. COMANDOS UTEIS

```bash
# Verificacao completa
bash ~/.cipher/verify-cipher.sh

# Status do Qdrant
systemctl --user status qdrant.service

# Reiniciar Qdrant
systemctl --user restart qdrant.service

# Ver collections e vetores
curl -s http://localhost:6333/collections | python3 -m json.tool

# Ver detalhes de uma collection
curl -s http://localhost:6333/collections/cipher_memory | python3 -m json.tool

# Ver logs do Qdrant
journalctl --user -u qdrant.service --since "1 hour ago" --no-pager

# RAM do Qdrant
systemctl --user status qdrant.service | grep Memory
```

---

## 9. PONTOS DE ATENCAO FUTUROS

1. **Ao atualizar o Node via nvm:** Os paths absolutos em `~/.claude.json` precisam ser atualizados para a nova versao
2. **Ao atualizar o Cipher:** Rodar `npm update -g @byterover/cipher` e verificar se o path do module mudou
3. **Ao atualizar o Qdrant:** Baixar novo binario, parar servico, substituir, reiniciar
4. **Backup:** O diretorio `/home/thiag/qdrant/storage/` contem todos os vetores. Faca backup periodico
5. **Monitoramento:** Se a RAM do Qdrant crescer muito, considerar ajustar `indexing_threshold_kb` no config
