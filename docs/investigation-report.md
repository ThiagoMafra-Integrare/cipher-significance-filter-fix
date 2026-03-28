# Relatório: Fix do Significance Filter do Cipher + Atualização da Skill

**Data:** 13/03/2026
**Executado por:** Claude (Opus 4.6) via Claude.ai + Thiago via Claude Code
**Ambiente:** WSL2 Ubuntu 24.04 · Cipher 0.3.0 · Qdrant v1.17.0 nativo · Node v22.22.0

---

## 1. PROBLEMA ORIGINAL

Durante a auditoria de segurança do checkout ASAAS no projeto Sistema Integrare Sites,
o Cipher retornou `extracted: 0` em **todas** as tentativas de save no knowledge memory
(0/9 na sessão inteira). O workspace memory funcionava normalmente.

### Sintomas observados

| Tentativa                         | Tool                                | Resultado                   |
| --------------------------------- | ----------------------------------- | --------------------------- |
| V-001 a V-006 (vulnerabilidades)  | `cipher_extract_and_operate_memory` | `extracted: 0, skipped: 1`  |
| CF Worker consolidado             | `cipher_extract_and_operate_memory` | `extracted: 0, skipped: 1`  |
| Migração Vercel→CF Pages          | `cipher_extract_and_operate_memory` | `extracted: 0, skipped: 1`  |
| Teste com formato atômico         | `cipher_extract_and_operate_memory` | `extracted: 0, skipped: 1`  |
| Teste com `useLLMDecisions: true` | `cipher_extract_and_operate_memory` | `extracted: 0, skipped: 1`  |
| Mesmos conteúdos                  | `cipher_workspace_store`            | `extracted: 1` (funcionava) |

### O que foi descartado como causa

| Hipótese                        | Resultado                                                               |
| ------------------------------- | ----------------------------------------------------------------------- |
| API key do OpenAI inválida      | Descartada — GPT-4o respondeu OK via curl                               |
| Dedup por similaridade          | Descartada — `cipher_memory_search` não encontrou nada similar          |
| Threshold muito baixo           | Descartado — testado com 0.95 e 0.99                                    |
| `useLLMDecisions: true`         | Descartado — não alterou o comportamento                                |
| System prompt do cipher-zai.yml | Descartado — o prompt controla o agente externo, não a extração interna |
| Formato do conteúdo             | Descartado — testado atômico, narrativo, com prefixo, sem prefixo       |
| Versão desatualizada            | Descartada — 0.3.0 é a versão mais recente no npm                       |

---

## 2. CAUSA RAIZ ENCONTRADA

### O Significance Filter

O Cipher 0.3.0 tem duas funções heurísticas hardcoded que rodam **ANTES** do
embedding, **ANTES** do LLM, **ANTES** do dedup:

- `isSignificantKnowledge(content)` — filtra knowledge saves
- `isWorkspaceSignificantContent(content)` — filtra workspace saves

Essas funções descartam conteúdo silenciosamente, retornando `extracted: 0, skipped: 1`
sem nenhuma indicação de que o filtro foi a causa.

### Como foi descoberto

Habilitando `CIPHER_LOG_LEVEL=debug` no bloco env do MCP (`~/.claude.json`),
os logs em `/tmp/cipher-mcp.log` revelaram:

```
ExtractAndOperateMemory: Skipping non-significant fact
ExtractAndOperateMemory: No significant facts found after filtering
```

O conteúdo era descartado antes de qualquer processamento.

### O bug específico

A função `isSignificantKnowledge` (linha 23226 de `core/index.cjs`) contém:

```javascript
const skipPatterns = [
  /\b(personal|profile|identity|username|login|password|email|address|phone)\b/i,
  // ... outros patterns
];
```

A palavra **`email`** nesta regex faz com que TODO conteúdo que mencione email
seja classificado como "informação pessoal" e descartado. Na auditoria do checkout,
todos os saves mencionavam "email" (Brevo email, campo email do form, endpoint de email).

### Problemas adicionais no filtro

1. **skipPatterns rodava ANTES de technicalPatterns** — mesmo que o conteúdo fosse
   técnico, se contivesse "email", "address", "phone", "login" ou "password",
   era descartado antes de chegar na verificação técnica.

2. **technicalPatterns é um whitelist em inglês** — conteúdo em português sem
   termos técnicos em inglês era descartado por não matchear nenhum pattern.

3. **O workspace também tinha filtro** — `isWorkspaceSignificantContent` aplicava
   lógica similar, embora com critérios ligeiramente diferentes.

### Localização no código

```
/home/thiag/.nvm/versions/node/v22.22.0/lib/node_modules/@byterover/cipher/dist/src/core/index.cjs
  Linha 23226: function isSignificantKnowledge(content)
  Linha ~37150: function isWorkspaceSignificantContent(content)

/home/thiag/.nvm/versions/node/v22.22.0/lib/node_modules/@byterover/cipher/dist/src/app/index.cjs
  Linha 25937: function isSignificantKnowledge(content)
  Linha ~39830: function isWorkspaceSignificantContent(content)
```

---

## 3. FIX APLICADO

### Patch

Ambas as funções foram patcheadas para sempre retornar `true`, desabilitando
o filtro de significância:

```javascript
// ANTES:
function isSignificantKnowledge(content) {
  // ... 60+ linhas de regex patterns
}

// DEPOIS:
function isSignificantKnowledge(content) {
  return true;
  // ... código original permanece mas nunca executa
}
```

### Arquivos patcheados (4 pontos)

| Arquivo                   | Função                          | Status                  |
| ------------------------- | ------------------------------- | ----------------------- |
| `dist/src/core/index.cjs` | `isSignificantKnowledge`        | Patcheado + backup .bak |
| `dist/src/core/index.cjs` | `isWorkspaceSignificantContent` | Patcheado + backup .bak |
| `dist/src/app/index.cjs`  | `isSignificantKnowledge`        | Patcheado + backup .bak |
| `dist/src/app/index.cjs`  | `isWorkspaceSignificantContent` | Patcheado + backup .bak |

### Backups

```
/home/thiag/.nvm/versions/node/v22.22.0/lib/node_modules/@byterover/cipher/dist/src/core/index.cjs.bak
/home/thiag/.nvm/versions/node/v22.22.0/lib/node_modules/@byterover/cipher/dist/src/app/index.cjs.bak
```

### Resultado após o patch

```
cipher_extract_and_operate_memory:
  extracted: 1, skipped: 0
  event: ADD, confidence: 0.95
  Status: SUCCESS
```

---

## 4. COMANDOS PARA REAPLICAR O PATCH

**Necessário após:** `npm update -g @byterover/cipher` ou mudança de versão do Node.

```bash
# Ajustar o path se a versão do Node mudou (verificar com: node --version)
CIPHER_CORE="/home/thiag/.nvm/versions/node/v22.22.0/lib/node_modules/@byterover/cipher/dist/src/core/index.cjs"
CIPHER_APP="/home/thiag/.nvm/versions/node/v22.22.0/lib/node_modules/@byterover/cipher/dist/src/app/index.cjs"

# Backups
cp "$CIPHER_CORE" "$CIPHER_CORE.bak"
cp "$CIPHER_APP" "$CIPHER_APP.bak"

# Patch knowledge filter
sed -i 's/function isSignificantKnowledge(content) {/function isSignificantKnowledge(content) { return true;/' "$CIPHER_CORE"
sed -i 's/function isSignificantKnowledge(content) {/function isSignificantKnowledge(content) { return true;/' "$CIPHER_APP"

# Patch workspace filter
sed -i 's/function isWorkspaceSignificantContent(content) {/function isWorkspaceSignificantContent(content) { return true;/' "$CIPHER_CORE"
sed -i 's/function isWorkspaceSignificantContent(content) {/function isWorkspaceSignificantContent(content) { return true;/' "$CIPHER_APP"

# Verificar
echo "=== Verificação ==="
grep "function isSignificantKnowledge" "$CIPHER_CORE" | head -1
grep "function isWorkspaceSignificantContent" "$CIPHER_CORE" | head -1
grep "function isSignificantKnowledge" "$CIPHER_APP" | head -1
grep "function isWorkspaceSignificantContent" "$CIPHER_APP" | head -1
# Todas devem conter "{ return true;" no início
```

---

## 5. COMO DIAGNOSTICAR SE O PATCH FOI PERDIDO

### Sintoma

Todos os saves de knowledge (e possivelmente workspace) retornam `extracted: 0`.

### Diagnóstico rápido

```bash
# 1. Verificar logs de debug
tail -20 /tmp/cipher-mcp.log | grep -i "non-significant\|No significant"
# Se aparecer "Skipping non-significant" → patch foi perdido

# 2. Verificar o patch no código
CIPHER_CORE="/home/thiag/.nvm/versions/node/v22.22.0/lib/node_modules/@byterover/cipher/dist/src/core/index.cjs"
grep "function isSignificantKnowledge" "$CIPHER_CORE" | head -1
# Deve conter "{ return true;" — se não contém, patch foi perdido
```

### Pré-requisito para diagnóstico

`CIPHER_LOG_LEVEL=debug` deve estar no bloco env do MCP em `~/.claude.json`.
Logs vão para `/tmp/cipher-mcp.log`.

---

## 6. ALTERAÇÕES NA CONFIGURAÇÃO

### 6.1 CIPHER_LOG_LEVEL adicionado ao MCP

**Arquivo:** `~/.claude.json` → `mcpServers.cipher.env`

**Adicionado:**

```json
"CIPHER_LOG_LEVEL": "debug"
```

**Motivo:** Sem debug, os logs de rejeição do significance filter são silenciosos.
Com debug, aparecem em `/tmp/cipher-mcp.log`.

### 6.2 System prompt do cipher-zai.yml atualizado

**Arquivo:** `/home/thiag/.cipher/cipher-zai.yml`

**Antes:**

```yaml
systemPrompt:
  content: |
    You are an AI programming assistant focused on coding and reasoning tasks...
```

**Depois:**

```yaml
systemPrompt:
  content: |
    You are a memory extraction engine. Your ONLY job is to extract and store facts using the available memory tools.
    MANDATORY BEHAVIOR:
    - When you receive text, ALWAYS call the memory extraction tool to store it
    - NEVER respond conversationally
    ...
```

**Nota:** Esta alteração NÃO resolveu o problema de knowledge (a causa era o significance
filter, não o system prompt). Mas é uma melhoria para o modo CLI do Cipher — força o
GPT-4o a usar as tools em vez de responder como chat. Pode ser revertida se causar
efeitos colaterais. Backup não foi criado para este arquivo — o conteúdo anterior está
documentado neste relatório.

**System prompt anterior (para reverter se necessário):**

```yaml
systemPrompt:
  enabled: true
  content: |
    You are an AI programming assistant focused on coding and reasoning tasks. You excel at:
    - Writing clean, efficient code
    - Debugging and problem-solving
    - Code review and optimization
    - Explaining complex technical concepts
    - Reasoning through programming challenges
    You should call each tool at most once per user request unless explicitly instructed otherwise.
```

---

## 7. ATUALIZAÇÕES NA SKILL cipher-memory-expert

**Arquivo:** `~/.claude/skills/cipher-memory-expert/SKILL.md`

### Alterações na versão anterior (antes da sessão de hoje)

A skill original cobria apenas o cenário de dedup (`extracted: 0, skipped: 1` por
similaridade). Não cobria:

- Falha de extração (`facts: []`)
- Significance filter silencioso
- Diagnóstico de falhas sistêmicas (ALL saves fail)
- Debug logging

### Alterações aplicadas — Versão 1 (Step 6 + formato atômico)

Criada durante a auditoria, ANTES de descobrir o significance filter:

| Seção                       | Mudança                                                                    |
| --------------------------- | -------------------------------------------------------------------------- |
| Step 4 (Verify Response)    | Distingue `skipped: 1` (dedup → Step 5) de `facts: []` (extração → Step 6) |
| **Step 6 (NOVO)**           | Recovery para extraction failure: simplificar → split → fallback workspace |
| Step 3 (Write Good Content) | Formato atômico documentado com exemplos bom/ruim                          |
| Cognitive Interrupt         | 4ª verificação: "Atomic format?"                                           |
| Session Save Workflow       | Etapa 5: fallback coverage                                                 |
| Red Flags                   | 2 novas: "vou adicionar mais contexto", "vou consolidar"                   |
| Common Mistakes             | 5 novas entradas sobre formato, prefixos, narrativas                       |
| Parameter Cheat Sheet       | Regras de formato atômico adicionadas                                      |
| Quick Diagnosis (NOVO)      | Tabela rápida: response → causa → step                                     |

### Alterações aplicadas — Versão 2 (significance filter patch)

Criada DEPOIS de descobrir o significance filter:

| Seção                                      | Mudança                                                                      |
| ------------------------------------------ | ---------------------------------------------------------------------------- |
| **Significance Filter Patch (NOVO, topo)** | Documentação completa do bug, patch, diagnóstico e reapply                   |
| Step 4 (Verify Response)                   | Nota: se TODOS os saves falharem, verificar patch primeiro                   |
| Step 6                                     | Primeiro passo: verificar patch antes de tentar recovery                     |
| Session Save Workflow                      | Etapa 5: "Check significance filter first (if ALL fail)"                     |
| Red Flags                                  | 3 entradas atualizadas: "If ALL saves fail, check significance filter patch" |
| Common Mistakes                            | Nova: "Ignore ALL saves failing → check patch status"                        |
| Quick Diagnosis                            | Primeira linha: "ALL saves → patch lost → reapply"                           |
| **Debug Logging (NOVO)**                   | `CIPHER_LOG_LEVEL=debug`, localização do log, mensagens-chave                |

---

## 8. ARQUIVOS CRIADOS/MODIFICADOS

### Criados

| Arquivo              | Propósito                                       |
| -------------------- | ----------------------------------------------- |
| `core/index.cjs.bak` | Backup do código original antes do patch        |
| `app/index.cjs.bak`  | Backup do código original antes do patch        |
| Este relatório       | Documentação da sessão para a pasta Cipher_WSL2 |

### Modificados

| Arquivo                                          | Alteração                                                           |
| ------------------------------------------------ | ------------------------------------------------------------------- |
| `~/.claude.json` (env do MCP cipher)             | Adicionado `CIPHER_LOG_LEVEL: debug`                                |
| `~/.cipher/cipher-zai.yml`                       | System prompt alterado (ver seção 6.2)                              |
| `dist/src/core/index.cjs`                        | Patch em `isSignificantKnowledge` e `isWorkspaceSignificantContent` |
| `dist/src/app/index.cjs`                         | Patch em `isSignificantKnowledge` e `isWorkspaceSignificantContent` |
| `~/.claude/skills/cipher-memory-expert/SKILL.md` | Atualização completa (ver seção 7)                                  |

---

## 9. PENDÊNCIAS

| Item                              | Prioridade | Descrição                                                                                                                               |
| --------------------------------- | ---------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| Issue no GitHub                   | Média      | Reportar o bug do skipPattern com "email" em campfirein/cipher                                                                          |
| Rotação de credenciais            | **ALTA**   | CloudFlare API Key, Brevo API Key e Vercel Token foram expostos em comandos bash durante o deploy da auditoria. Regenerar imediatamente |
| Re-save da auditoria no knowledge | Baixa      | Com o patch ativo, os dados da auditoria (V-001 a V-006) podem agora ser salvos no knowledge memory. Já estão no workspace              |
| Monitorar atualizações do Cipher  | Contínua   | Se npm update sobrescrever o patch, reaplicar (ver seção 4)                                                                             |

---

## 10. LIÇÕES APRENDIDAS

1. **Logs de debug são essenciais.** Sem `CIPHER_LOG_LEVEL=debug`, o significance filter
   é invisível. A mensagem `extracted: 0, skipped: 1` é idêntica para dedup e para
   filtro de significância — só os logs distinguem.

2. **`success: true` não significa que algo foi salvo.** O campo `success` indica que
   a operação não teve erro técnico. O indicador real é `extracted >= 1`.

3. **Filtros heurísticos são frágeis.** Um regex bem-intencionado ("não salve dados
   pessoais como email") bloqueou toda informação técnica sobre endpoints de email,
   campos de formulário com email, e APIs de envio de email.

4. **workspace_store tem pipeline diferente.** Mesmo com o filtro ativo, o workspace
   conseguiu salvar porque usa `workspaceInfo` estruturado que passa por uma lógica
   de extração diferente da knowledge. Por isso o workspace funcionava e o knowledge não.

5. **Investigar o código-fonte é viável.** Cipher é open-source e o código compilado
   (.cjs) é legível. `grep` + `sed` no código-fonte foram suficientes para encontrar
   e corrigir o bug em minutos.
