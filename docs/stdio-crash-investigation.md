# Relatório: Fix do STDIO Crash do Cipher MCP

**Data:** 14/04/2026
**Executado por:** Claude (Opus 4.6) via Claude Code + Thiago
**Ambiente:** WSL2 Ubuntu 24.04 · Cipher 0.3.0 · Qdrant v1.17.0 nativo · Node v22.22.0

---

## 1. PROBLEMA ORIGINAL

O Cipher MCP desconectava de todas as sessões Claude Code (WSL2 e VPS) após a primeira
chamada de tool. O processo fazia shutdown gracioso imediatamente após responder.

### Sintomas observados

| Evento             | Detalhe                                                           |
| ------------------ | ----------------------------------------------------------------- |
| Primeira tool call | Executada com sucesso, resposta retornada                         |
| Imediatamente após | Log: `[MCP Mode] Shutting down aggregator MCP server...`          |
| Claude Code        | Respawna o processo, repete o ciclo                               |
| Resultado          | Cipher funcional por 1-2 calls, depois desconecta permanentemente |

### Logs observados

```
JSON Parse error: Unexpected identifier "version"
STDIO connection dropped after 24s uptime
```

### O que foi descartado como causa

| Hipótese                        | Resultado                                                      |
| ------------------------------- | -------------------------------------------------------------- |
| Processo órfão                  | Parcialmente correto — órfãos existiam, mas matar não resolvia |
| Signal handler (SIGTERM/SIGINT) | Descartado — nenhum signal externo sendo enviado               |
| Timeout ou idle timer           | Descartado — não existe no código                              |
| Bug do @byterover/cipher 0.3.0  | Parcialmente correto — é um bug, mas no código, não na versão  |

---

## 2. CAUSA RAIZ ENCONTRADA

### console.log residuais corrompem o protocolo STDIO

O Cipher MCP usa **stdout** como canal JSON-RPC para comunicação com o Claude Code.
O protocolo exige que APENAS mensagens JSON-RPC válidas sejam escritas em stdout.

O Winston logger do Cipher está corretamente configurado para escrever em **stderr**:

```javascript
// Linha 9163 de dist/src/app/index.cjs
stderrLevels: Object.keys(logLevels);
// Redirect all log levels to stderr
```

Porém, existem dezenas de `console.log` residuais (debug leftovers) espalhados pelo
código que **bypassam o logger** e escrevem diretamente para stdout.

### Os culpados diretos (handler search_memory)

Os `console.log` dentro do handler `search_memory` disparam em TODA chamada de
`cipher_memory_search`:

| Linha | Conteúdo                                                            |
| ----- | ------------------------------------------------------------------- |
| 26948 | `console.log("search_memory tool called with:", {...})`             |
| 27171 | `console.log("search rawPayload", rawPayload)`                      |
| 27173 | `console.log("search payload", payload)`                            |
| 27185 | `console.log("search baseResult", baseResult)`                      |
| 27133 | `console.log("MemorySearch: Knowledge store search failed", {...})` |

### Outros console.log potencialmente problemáticos

| Linha | Conteúdo                                                 | Quando dispara        |
| ----- | -------------------------------------------------------- | --------------------- |
| 9196  | `console.log(boxen(...))` — displayAIResponse            | Modo CLI              |
| 9208  | `console.log(boxen(...))` — toolCall                     | Modo CLI              |
| 14981 | `console.log("Knowledge graph result")`                  | Knowledge graph ops   |
| 15056 | `console.log("Knowledge graph result", ...)`             | Knowledge graph error |
| 30052 | `console.log("Attempting to parse embedding config...")` | Inicialização         |

### Sequência do crash

```
1. Claude Code envia request MCP via stdin do Cipher
2. Cipher executa cipher_memory_search → handler em linha 26945
3. Handler executa console.log (linhas 26948, 27171, 27173, 27185)
4. console.log escreve objetos JavaScript para stdout
5. Output mistura com o JSON-RPC response no mesmo stream
6. Claude Code MCP client tenta parsear → "JSON Parse error: Unexpected identifier"
7. Claude Code fecha o pipe stdin
8. process.stdin perde o reader → event loop sem handles ativos
9. process.on("SIGTERM", handleShutdown) ou exit natural
10. Log: "[MCP Mode] Shutting down aggregator MCP server..."
```

### Por que era difícil diagnosticar

1. O **shutdown é gracioso** — parece um exit normal, não um crash
2. O processo **responde com sucesso** na primeira call — o JSON-RPC response é válido
3. O `console.log` que corrompe o stream acontece **durante** o processamento, não antes
4. A mensagem de erro ("JSON Parse error") aparece no lado do **cliente** (Claude Code), não no Cipher
5. Matar processos órfãos ajudava temporariamente (novo spawn → funciona 1x → crash de novo)

---

## 3. FIX APLICADO

### Patch (3 linhas)

No início de `startMcpMode` (linha 52531 de `dist/src/app/index.cjs`), redirecionar
`console.log`, `console.info` e `console.warn` para `process.stderr`:

```javascript
// ANTES:
async function startMcpMode(agent, opts) {
  if (!agent) {

// DEPOIS:
async function startMcpMode(agent, opts) {
  // PATCH: redirect stray console.log/info/warn to stderr to prevent stdout MCP corruption
  console.log = (...args) => process.stderr.write(args.map(String).join(' ') + '\n');
  console.info = console.log;
  console.warn = console.log;
  if (!agent) {
```

### Por que este approach

- **Mínimo invasivo:** 3 linhas no ponto de entrada do modo MCP
- **Não altera handlers individuais:** Todos os `console.log` residuais são cobertos automaticamente
- **Não afeta o Winston logger:** O logger já usa stderr via `stderrLevels`
- **Não afeta outros modos:** O patch só roda quando `startMcpMode` é chamado (modo CLI e API não são afetados)

### Arquivo patcheado

| Arquivo                  | Linha       | Função         | Status    |
| ------------------------ | ----------- | -------------- | --------- |
| `dist/src/app/index.cjs` | 52531-52534 | `startMcpMode` | Patcheado |

### Resultado após o patch

```
cipher_memory_search #1: SUCCESS (resultados retornados)
cipher_memory_search #2: SUCCESS (processo sobreviveu entre chamadas)
cipher_extract_and_operate_memory: SUCCESS (extracted: 1)
Processo Cipher: ESTÁVEL (sem shutdown entre chamadas)
```

---

## 4. COMANDOS PARA REAPLICAR O PATCH

**Necessário após:** `npm update -g @byterover/cipher` ou mudança de versão do Node.

```bash
CIPHER_APP="$(dirname $(which cipher))/../lib/node_modules/@byterover/cipher/dist/src/app/index.cjs"

# Backup
cp "$CIPHER_APP" "$CIPHER_APP.bak"

# Patch: adicionar redirect de console no início de startMcpMode
sed -i '/^async function startMcpMode(agent, opts) {$/a\  // PATCH: redirect stray console.log/info/warn to stderr to prevent stdout MCP corruption\n  console.log = (...args) => process.stderr.write(args.map(String).join('"'"''"'"') + '"'"'\\n'"'"');\n  console.info = console.log;\n  console.warn = console.log;' "$CIPHER_APP"

# Verificar
grep -A 4 "async function startMcpMode" "$CIPHER_APP" | head -6
# Deve mostrar as 3 linhas de redirect após a declaração da função
```

---

## 5. COMO DIAGNOSTICAR SE O PATCH FOI PERDIDO

### Sintoma

Cipher MCP desconecta após a primeira chamada de tool. Logs do Claude Code mostram
"STDIO connection dropped" ou "JSON Parse error".

### Diagnóstico rápido

```bash
# 1. Verificar se o patch está presente
CIPHER_APP="$(dirname $(which cipher))/../lib/node_modules/@byterover/cipher/dist/src/app/index.cjs"
grep "redirect stray console.log" "$CIPHER_APP"
# Se não retornar nada → patch foi perdido

# 2. Verificar processos (healthcheck)
~/dev/scripts/cipher-healthcheck.sh
# Se múltiplos processos → órfãos acumulando por crashes repetidos
```

---

## 6. RELAÇÃO COM O SIGNIFICANCE FILTER FIX

Este fix é **independente** do significance filter fix documentado em
`investigation-report.md`. Os dois bugs coexistem na mesma versão (0.3.0):

| Bug                 | Efeito                        | Causa                                            | Fix                                                                       |
| ------------------- | ----------------------------- | ------------------------------------------------ | ------------------------------------------------------------------------- |
| Significance filter | Saves retornam `extracted: 0` | Regex descarta conteúdo como "não significativo" | `return true` nas funções de filtro ou `DISABLE_SIGNIFICANCE_FILTER=true` |
| STDIO crash         | Processo morre após 1-2 calls | `console.log` corrompe stdout/JSON-RPC           | Redirect console para stderr em `startMcpMode`                            |

Ambos os patches devem ser aplicados. O script `patches/apply-all.sh` aplica os dois.

---

## 7. INFRAESTRUTURA PREVENTIVA

### cipher-healthcheck.sh

Script criado em `~/dev/scripts/cipher-healthcheck.sh` para detectar e matar processos
Cipher órfãos no WSL2. O crash repetido do STDIO gerava acúmulo de processos órfãos
que interferiam com novas conexões MCP.

### Hook SessionStart

Hook configurado em `~/.claude/settings.json` para rodar o healthcheck automaticamente
no início de cada sessão Claude Code:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup",
        "hooks": [
          {
            "type": "command",
            "command": "/home/thiag/dev/scripts/cipher-healthcheck.sh",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

---

## 8. LIÇÕES APRENDIDAS

1. **stdout é sagrado em MCP STDIO.** Qualquer output que não seja JSON-RPC válido
   corrompe o protocolo. `console.log` é o inimigo silencioso — parece inofensivo mas
   escreve para stdout por default.

2. **Winston logger ≠ console.log.** O Cipher tem um logger bem configurado (stderr),
   mas debug leftovers usando `console.log` direto bypassam toda a configuração.

3. **O crash parece gracioso.** "Shutting down aggregator MCP server" parece um exit
   intencional, não um crash. Isso atrasa o diagnóstico porque faz parecer que algo
   está mandando o processo parar.

4. **Processos órfãos são sintoma, não causa.** Matar órfãos resolve temporariamente
   (novo spawn funciona 1x), mas o crash se repete. O fix real é no código.

5. **Grep no código compilado funciona.** Mesmo `.cjs` compilado é legível. `grep` +
   `sed` são suficientes para encontrar e corrigir bugs em minutos.
