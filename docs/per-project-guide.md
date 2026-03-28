# Guia: Como Usar o Cipher em Qualquer Projeto

**Autor:** Thiago (Integrare Tecnologia)
**Versao:** 1.0 — 2026-02-25
**Pre-requisito:** Cipher ja configurado globalmente (ver RELATORIO-CONFIGURACAO-CIPHER.md)

---

## Visao Geral

O Cipher ja esta disponivel em TODOS os projetos via config global (`~/.claude.json`).
Porem, sem instrucoes explicitas no CLAUDE.md do projeto, o Claude nao sabe:

- **O que** salvar no Cipher
- **Quando** salvar
- **Como verificar** que salvou corretamente
- **O que manter em arquivos** vs **o que delegar ao Cipher**

Este guia resolve isso com um protocolo padrao.

---

## Passo 1: Verificar que o Cipher esta funcionando

Antes de configurar qualquer projeto, confirme que a infraestrutura esta OK:

```bash
bash ~/.cipher/verify-cipher.sh
```

Deve mostrar:

- Qdrant rodando em localhost:6333
- Collections existentes (cipher_memory, workspace_memory, reflection_memory)
- Servico systemd ativo
- Cipher instalado

Se algo falhar, consulte o RELATORIO-CONFIGURACAO-CIPHER.md para troubleshooting.

---

## Passo 2: Definir a Estrategia de Memoria do Projeto

Antes de tocar no CLAUDE.md, decida o que vai para onde:

### O que FICA em arquivos (docs/):

| Tipo                                           | Motivo                                      |
| ---------------------------------------------- | ------------------------------------------- |
| Estado atual do sistema (diagrama, descritivo) | Precisa ser lido de uma vez como referencia |
| Regras de negocio vigentes                     | Sao poucas e precisam estar sempre visiveis |
| Configuracoes de deploy/infra                  | Sao consultadas toda vez que se faz deploy  |
| Tarefas ativas (proximas a fazer)              | Claude precisa ver na hora, sem buscar      |

### O que VAI para o Cipher:

| Tipo                                        | Motivo                                                     |
| ------------------------------------------- | ---------------------------------------------------------- |
| Historico de progresso (sessoes anteriores) | Cresce infinitamente, so consulta quando precisa           |
| Decisoes tecnicas e suas razoes             | Busca semantica encontra melhor que grep em arquivo grande |
| Bugs encontrados e solucoes                 | Evita resolver o mesmo bug duas vezes                      |
| Padroes de codigo descobertos               | Reutiliza em contextos similares                           |
| Contexto de implementacao                   | "Por que fizemos X e nao Y"                                |
| Testes realizados e resultados              | Referencia futura                                          |

### Regra de ouro:

> **Se a informacao so cresce e raramente e consultada inteira, vai pro Cipher.**
> **Se a informacao e consultada toda sessao como referencia, fica em arquivo.**

---

## Passo 3: Adicionar o Protocolo Cipher ao CLAUDE.md do Projeto

Copie e adapte o bloco abaixo para o CLAUDE.md do seu projeto.
Substitua `[NOME_PROJETO]` e `[DESCRICAO]` conforme necessario.

```markdown
## Cipher Memory Protocol

O Cipher esta disponivel como memoria persistente para este projeto.
Use-o para armazenar e recuperar contexto entre sessoes.

### ANTES de iniciar trabalho:

1. Use `cipher_workspace_search` com query: "[NOME_PROJETO] progresso recente"
2. Use `cipher_memory_search` com query relevante a tarefa (ex: "bug login [NOME_PROJETO]")
3. Informe ao usuario o que encontrou (ou que nao encontrou nada)

### APOS concluir trabalho significativo:

1. **SALVAR** — Use `cipher_workspace_store` com:
   - Descricao clara do que foi feito
   - Arquivos alterados
   - Decisoes tomadas e suas razoes
   - Bugs encontrados/corrigidos
   - Testes realizados
   - SEMPRE incluir "[NOME_PROJETO]" no texto para facilitar busca futura
   - **OBRIGATORIO**: passar `options: {"similarityThreshold": 0.95}` para evitar
     que o Cipher pule o save por detectar similaridade tematica com entradas existentes
   - Apos o save, verificar no resultado: `extracted` deve ser >= 1.
     Se `extracted: 0, skipped: 1`, o save FOI PULADO — repetir com conteudo mais detalhado

2. **VERIFICAR** — Imediatamente apos salvar, use `cipher_workspace_search` com
   termos-chave do que acabou de salvar. Confirme ao usuario:
   - "Salvo no Cipher e verificado: [resumo do que foi encontrado na busca]"
   - Se a busca NAO retornar o que foi salvo, tente salvar novamente

3. **INFORMAR** — Diga ao usuario exatamente o que foi salvo e o resultado da verificacao

### Categorias de memoria (TODAS requerem `options: {"similarityThreshold": 0.95}`):

- **cipher_workspace_store**: progresso de sessao, bugs, implementacoes (use SEMPRE) — threshold default 0.8
- **cipher_extract_and_operate_memory**: decisoes tecnicas, padroes de arquitetura, regras de negocio — threshold default 0.6 (MAIS agressivo!)
- **cipher_store_reasoning_memory**: raciocinio complexo, trade-offs avaliados

### Quando NAO usar:

- Correcoes triviais (typos, formatacao, ajustes de estilo)
- Quando o usuario pedir explicitamente para nao usar
- Informacao que ja esta no CLAUDE.md ou MEMORY.md do projeto
```

---

## Passo 4: Atualizar os Arquivos de Documentacao

Com o Cipher absorvendo o historico, os arquivos de docs podem ser enxugados:

### Estrategia de migracao:

1. **NAO delete nada dos arquivos atuais ainda** — primeiro migre para o Cipher
2. Peca ao Claude para ler o arquivo grande e extrair blocos de informacao historica
3. Para cada bloco, salve no Cipher com contexto adequado
4. Apos confirmar que tudo esta no Cipher, reduza o arquivo para conter apenas o estado ATUAL

### Exemplo pratico (arquivo de demandas):

**Antes (1.272 linhas, append-only):**

```
Sessao 2026-02-16: fiz X, Y, Z...
Sessao 2026-02-18: corrigido bug A, implementado B...
Sessao 2026-02-20: ...
[... 50 sessoes de historico ...]
PENDENTE: tarefa 1
PENDENTE: tarefa 2
```

**Depois (~100-200 linhas):**

```
# Demandas Pendentes (estado atual)
## Em andamento
- Tarefa X (descricao)

## Proximo
- Tarefa Y (descricao)

## Backlog
- Tarefa Z (descricao)

---
Historico completo de sessoes: armazenado no Cipher
(buscar: "[NOME_PROJETO] sessao YYYY-MM-DD" ou "[NOME_PROJETO] progresso")
```

---

## Passo 5: Protocolo de Verificacao (o mais importante)

A verificacao e o que garante que nada se perde. O fluxo completo e:

```
[Claude conclui trabalho]
        |
        v
[SALVAR no Cipher com options.similarityThreshold: 0.95]
        |
        v
[Checar resultado: extracted >= 1?]
   |           |
  SIM         NAO (extracted:0, skipped:1)
   |           |
   v           v
[BUSCAR no   [Save foi PULADO por
 Cipher]      similaridade — repetir
   |          com conteudo mais detalhado]
   v           |
[Encontrou?]   v
   |        [SALVAR de novo]
  SIM  NAO     |
   |    |      v
   v    v   [Checar extracted >= 1?]
[OK] [Alertar     |
      usuario] [Continuar fluxo...]
```

### ALERTA CRITICO: workspace_store pode pular saves silenciosamente

O `cipher_workspace_store` tem um threshold de similaridade interno (default ~0.8)
que compara o conteudo novo com entradas existentes. Se detectar que o conteudo e
"parecido demais" com algo ja armazenado, ele PULA o save sem erro (retorna
`extracted: 0, skipped: 1`).

**Isso acontece mesmo quando o conteudo e genuinamente diferente** — basta ser do
mesmo dominio tematico (ex: dois projetos Next.js com Supabase).

**Solucao**: SEMPRE passar `options: {"similarityThreshold": 0.95}` no workspace_store.

### Formato da mensagem de verificacao:

```
**Cipher Memory — Salvo e Verificado**
- Tipo: workspace / knowledge / reasoning
- Conteudo: [resumo em 1-2 linhas do que foi salvo]
- Save: extracted=[N], skipped=[N]
- Verificacao: busca por "[termos]" retornou [N] resultado(s), similaridade [X]
- Status: OK / FALHA (save pulado) / FALHA (busca vazia)
```

---

## Passo 6: Template Completo para CLAUDE.md

Aqui esta um template pronto para copiar e adaptar:

```markdown
## Cipher Memory Protocol — [NOME_PROJETO]

### Regras:

1. SEMPRE buscar contexto no Cipher antes de tarefas complexas
2. SEMPRE salvar progresso no Cipher apos concluir trabalho significativo
3. SEMPRE verificar que o save funcionou (buscar imediatamente apos salvar)
4. SEMPRE incluir "[NOME_PROJETO]" nos textos salvos para facilitar busca
5. SEMPRE informar ao usuario o resultado da verificacao

### Fluxo obrigatorio pos-trabalho:

1. `cipher_workspace_store` com `options: {"similarityThreshold": 0.95}` — salvar progresso (default 0.8)
2. Se decisao tecnica: `cipher_extract_and_operate_memory` com `options: {"similarityThreshold": 0.95}` (default 0.6!)
3. Checar resultado: `extracted` deve ser >= 1. Se `skipped: 1`, repetir com mais detalhe
4. `cipher_workspace_search` — buscar o que acabou de salvar
5. Confirmar ao usuario: "Cipher: salvo e verificado — extracted=[N], busca=[N] resultados"

### Busca pre-trabalho:

- `cipher_workspace_search`: "[NOME_PROJETO] progresso recente"
- `cipher_memory_search`: termos relevantes a tarefa atual

### O que salvar:

- Implementacoes concluidas (o que, onde, por que)
- Bugs corrigidos (sintoma, causa, solucao)
- Decisoes tecnicas (opcoes avaliadas, escolha, motivo)
- Testes realizados (o que testou, resultados)
- Configuracoes alteradas (antes/depois)
```

---

## Checklist Rapido — Novo Projeto

- [ ] `bash ~/.cipher/verify-cipher.sh` — infraestrutura OK
- [ ] Definir o que fica em arquivo vs Cipher (Passo 2)
- [ ] Adicionar protocolo Cipher ao CLAUDE.md (Passo 3)
- [ ] Se houver arquivos grandes, planejar migracao (Passo 4)
- [ ] Testar: pedir ao Claude para salvar algo e verificar
- [ ] Confirmar que a busca retorna o que foi salvo

---

## Troubleshooting

| Problema                                          | Causa provavel                                      | Solucao                                                                 |
| ------------------------------------------------- | --------------------------------------------------- | ----------------------------------------------------------------------- |
| Claude nao usa o Cipher                           | Falta instrucao no CLAUDE.md do projeto             | Adicionar protocolo (Passo 3)                                           |
| Save retorna `extracted:0, skipped:1` (workspace) | Threshold de similaridade muito baixo (default 0.8) | Passar `options: {"similarityThreshold": 0.95}`                         |
| Save retorna `extracted:0, skipped:1` (knowledge) | Threshold AINDA MAIS baixo (default 0.6!)           | Passar `options: {"similarityThreshold": 0.95}`                         |
| Save funciona mas busca nao encontra              | Texto salvo muito diferente dos termos de busca     | Usar termos mais especificos, incluir nome do projeto                   |
| Cipher retorna erro                               | Qdrant pode ter caido                               | `systemctl --user restart qdrant.service`                               |
| Busca retorna resultados de outro projeto         | Texto nao inclui nome do projeto                    | Sempre incluir `[NOME_PROJETO]` no conteudo                             |
| Similaridade muito baixa (<0.3)                   | Embeddings diferentes demais                        | Reformular a query com mais contexto                                    |
| Save funciona na knowledge mas nao no workspace   | workspace_store tem threshold mais agressivo        | Usar knowledge via `cipher_extract_and_operate_memory` como alternativa |
