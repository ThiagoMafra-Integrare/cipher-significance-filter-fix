---
name: cipher-memory-expert
description: "Deterministic protocol for Cipher memory saves. Use whenever saving to Cipher (cipher_extract_and_operate_memory, cipher_workspace_store, cipher_store_reasoning_memory), when saves are skipped silently, extracted is 0, agent loops retrying, or choosing between knowledge vs workspace memory. Also trigger on: 'salve o progresso', 'salve no Cipher', 'persista no Cipher', 'guarde essa decisão', 'certifique-se que salvou', 'save progress', 'persist to Cipher', any instruction to preserve session work in Cipher."
---

# Cipher Memory Expert

Deterministic protocol for saving to Cipher without silent failures. Cipher's dedup silently returns `extracted: 0, skipped: 1`. This skill replaces guesswork with a fixed sequence.

## CRITICAL: Significance Filter Patch (2026-03-13)

Cipher 0.3.0 has a hardcoded significance filter (`isSignificantKnowledge` and `isWorkspaceSignificantContent`) that runs BEFORE embedding, BEFORE LLM, BEFORE dedup. It silently discards content it considers "non-significant" — returning `extracted: 0, skipped: 1` with no indication that the filter was the cause.

### The Bug

The filter's `skipPatterns` include:

```javascript
/\b(personal|profile|identity|username|login|password|email|address|phone)\b/i;
```

The word **`email`** in this regex causes ALL content mentioning email (email endpoints, email fields, email APIs, email sending) to be classified as "personal information" and silently discarded. This also affects words like `address`, `phone`, `password`, `login`, and `profile` — all of which appear frequently in legitimate technical content.

Additionally, even content that passes skipPatterns must match `technicalPatterns` (a whitelist of programming terms). Content in Portuguese or non-English languages may fail this check because the patterns are English-only.

### The Patch

Both significance functions were patched to always return `true`, bypassing the filter entirely:

**Files patched (4 total):**

```
/home/thiag/.nvm/versions/node/v22.22.0/lib/node_modules/@byterover/cipher/dist/src/core/index.cjs
/home/thiag/.nvm/versions/node/v22.22.0/lib/node_modules/@byterover/cipher/dist/src/app/index.cjs
```

**Functions patched (2 per file):**

- `isSignificantKnowledge(content)` → `{ return true; }`
- `isWorkspaceSignificantContent(content)` → `{ return true; }`

**Backups:** `.bak` files in the same directories.

### How to Diagnose if Patch is Lost

If saves start returning `extracted: 0` for all content again:

1. Check the debug log:

```bash
tail -20 /tmp/cipher-mcp.log | grep -i "non-significant\|No significant"
```

2. If you see `Skipping non-significant fact` or `No significant facts found after filtering`, the patch was lost.

3. Verify the patch is in place:

```bash
CIPHER_CORE="/home/thiag/.nvm/versions/node/v22.22.0/lib/node_modules/@byterover/cipher/dist/src/core/index.cjs"
grep "function isSignificantKnowledge" "$CIPHER_CORE" | head -1
```

- If output contains `{ return true;` → patch is active
- If output is just `function isSignificantKnowledge(content) {` → patch was lost

### How to Reapply the Patch

Run this after any Cipher update (`npm update -g @byterover/cipher`):

```bash
CIPHER_CORE="/home/thiag/.nvm/versions/node/v22.22.0/lib/node_modules/@byterover/cipher/dist/src/core/index.cjs"
CIPHER_APP="/home/thiag/.nvm/versions/node/v22.22.0/lib/node_modules/@byterover/cipher/dist/src/app/index.cjs"

cp "$CIPHER_CORE" "$CIPHER_CORE.bak"
cp "$CIPHER_APP" "$CIPHER_APP.bak"

sed -i 's/function isSignificantKnowledge(content) {/function isSignificantKnowledge(content) { return true;/' "$CIPHER_CORE"
sed -i 's/function isSignificantKnowledge(content) {/function isSignificantKnowledge(content) { return true;/' "$CIPHER_APP"
sed -i 's/function isWorkspaceSignificantContent(content) {/function isWorkspaceSignificantContent(content) { return true;/' "$CIPHER_CORE"
sed -i 's/function isWorkspaceSignificantContent(content) {/function isWorkspaceSignificantContent(content) { return true;/' "$CIPHER_APP"

echo "Patch applied. Verify:"
grep "function isSignificantKnowledge" "$CIPHER_CORE" | head -1
grep "function isWorkspaceSignificantContent" "$CIPHER_CORE" | head -1
```

**IMPORTANT:** If Node.js version changes (nvm), the path changes too. Replace `v22.22.0` with the current version from `node --version`.

---

## Three Separate Memory Systems

```
cipher_extract_and_operate_memory  →  cipher_memory (knowledge)
   search: cipher_memory_search
   dedup: cosine similarity (default 0.6 — OVERRIDE to 0.95)

cipher_workspace_store  →  workspace_memory (workspace)
   search: cipher_workspace_search
   dedup: cosine similarity (default 0.8 — OVERRIDE to 0.95)

cipher_store_reasoning_memory  →  reflection_memory
   search: cipher_search_reasoning_patterns
   dedup: NONE — skip only by qualityScore or shouldStore: false
```

**They do NOT share data.** Saving via one and searching the other returns nothing. This is the #1 cause of "save didn't work" false alarms.

| Content Type                                         | Save Tool                           | Search Tool                        |
| ---------------------------------------------------- | ----------------------------------- | ---------------------------------- |
| Technical decisions, patterns, architecture, code    | `cipher_extract_and_operate_memory` | `cipher_memory_search`             |
| Session progress, project status, bugs, team context | `cipher_workspace_store`            | `cipher_workspace_search`          |
| Reasoning traces with evaluation                     | `cipher_store_reasoning_memory`     | `cipher_search_reasoning_patterns` |

## Before You Save: Pre-Flight Check

**Before ANY save operation, ALWAYS search first.** This prevents unnecessary saves and explains dedup behavior in advance.

1. Search the MATCHING collection with a keyword query from the content you're about to save
2. Review results: does the information already exist (partially or fully)?
3. If **already exists and current** → skip save, inform user it's already persisted
4. If **exists but outdated** → use UPDATE framing (knowledge memory only)
5. If **does not exist** → proceed with save

This step eliminates 80% of dedup frustrations. When you know what's already stored, you write content that is naturally distinct.

## The Save Protocol

### Step 1: Choose Tool (table above)

### Step 2: ALWAYS Pass Threshold (knowledge & workspace only)

```json
{ "options": { "similarityThreshold": 0.95 } }
```

**NEVER omit this.** Defaults (0.6 knowledge, 0.8 workspace) silently skip most saves.

**Exception:** `cipher_store_reasoning_memory` does NOT accept `options`. It uses `evaluation.qualityScore` (min 0.3) and `evaluation.shouldStore` instead.

### Step 3: Write Good Content

Bad content gets deduped even when it shouldn't. Good content is naturally distinct.

**Rules for `interaction` strings:**

- One topic per save. "Decisão de usar Redis + bug no deploy + alteração na API" → split into 3 saves
- Lead with the SPECIFIC fact, not generic context: "Redis TTL alterado de 30min para 2h por conta de cache miss rate de 45%" (good) vs "Fizemos uma alteração no cache" (bad — too generic, will match any cache-related entry)
- Include concrete values: versions, dates, numbers, names, error codes
- 200-500 chars is the sweet spot. Under 100 chars → too vague → matches everything. Over 2000 chars → embedding diluted → poor retrieval later

**Format for knowledge (`cipher_extract_and_operate_memory`):**
The internal LLM extracts structured facts from the `interaction` string. To maximize extraction success, use the ATOMIC FACT format:

```
GOOD (atomic, extractable):
"Redis cache TTL configurado para 2h na API de agendamento do CLINOS. Versão: Redis 7.2. Motivo: cache miss rate de 45% em horário de pico."

BAD (narrative, hard to extract):
"[SECURITY-AUDIT][Sistema Integrare][2026-03-13] Vulnerabilidade V-001 CORRIGIDA: Zero validação client-side no formulário Fale Conosco (apps/onboarding-sucesso/index.html). Antes: campos name/email/subject/message sem maxlength, sem pattern — input de 10.000 chars aceito. Depois: maxlength (name:100, email:254, subject:200, message:5000)..."
```

Why: The internal LLM looks for discrete facts it can extract as structured data. Narrative text with multiple facts, before/after comparisons, and decorative prefixes confuses the extractor — it returns `facts: []` (empty extraction, zero stored).

**When saving multiple items:** Save them ONE AT A TIME. Verify each before the next. `interaction` accepts `string[]` but each element is deduped independently — if one fails, you won't know which.

### Step 4: Verify Response

**For knowledge & workspace:**

```
extracted >= 1  →  SUCCESS. Proceed to next item.
extracted: 0, skipped: 1  →  DEDUP SKIP → Step 5
extracted: 0, facts: []   →  EXTRACTION FAILURE → Step 6
```

**IMPORTANT:** If `extracted: 0` occurs for ALL saves (not just one), check the significance filter patch first — see "How to Diagnose if Patch is Lost" at the top of this skill.

**For reasoning memory:**

```
stored: true  →  SUCCESS
stored: false + "quality_threshold"  →  Set shouldStore: true or qualityScore > 0.3
stored: false + validationErrors:
   "trace.steps is empty" → Add at least one step with type + content
   "evaluation is missing" → Add evaluation with qualityScore + issues + suggestions
   "trace.metadata is missing" → Add extractedAt, stepCount, conversationLength
```

### Step 5: Recovery When Skipped by Dedup (knowledge & workspace only)

**DETERMINISTIC sequence. Follow EXACTLY in order. Do NOT improvise.**

1. **Search** the MATCHING collection with keywords from the content
2. **Found similar entry?** → Compare semantics. If the existing entry covers the same information → save was correctly skipped (real duplicate). Done.
3. **Not found OR found but different information?** → The content collided with an unrelated entry. Add structural prefix and retry:
   ```
   Original: "Redis cache TTL configurado para 30 minutos"
   Prefixed: "[CLINOS][2026-03-13] Redis cache TTL configurado para 30 minutos na API de agendamento"
   ```
   The prefix + additional context shifts the embedding enough to pass dedup.
4. **Still skipped at 0.95?** → Retry with `similarityThreshold: 0.99`
5. **Still skipped at 0.99?** → This means content is >99% similar to an existing entry. Run a broad search to find it. If found, the information IS stored — just under different wording. Accept it. If truly not found anywhere, report to user: "Protocol exhausted. Recommend checking Qdrant or Cipher logs."

**Maximum attempts: 3.** After that, STOP. Do NOT loop.

### Step 6: Recovery When Extraction Fails (knowledge only — facts: [])

**This is DIFFERENT from dedup skip.** The internal LLM could not extract structured facts from the `interaction` string. The content never reached the dedup stage. Threshold changes will NOT help.

**Diagnosis:** Response shows `extracted: 0` AND `facts: []` (empty array) or no `skipped` count. This means the LLM extractor returned zero facts — not because of similarity, but because it could not parse the content.

**FIRST:** Check if the significance filter patch is still active (see top of this skill). If all saves are failing, the patch was likely lost after a Cipher update.

**DETERMINISTIC recovery sequence (if patch is confirmed active):**

1. **Simplify to atomic fact format.** Strip all decoration and rewrite as a single, direct statement:

   ```
   FAILED: "[SECURITY-AUDIT][Sistema Integrare][2026-03-13] Vulnerabilidade V-001 CORRIGIDA:
   Zero validação client-side no formulário Fale Conosco. Antes: campos sem maxlength.
   Depois: maxlength name:100 email:254..."

   RETRY AS: "Formulário Fale Conosco do Sistema Integrare não tinha validação de input.
   Adicionado maxlength nos campos: name 100, email 254, subject 200, message 5000.
   Validação server-side duplicada no CloudFlare Worker."
   ```

   Rules for atomic format:
   - **No prefixes** like `[PROJECT][DATE]`, `FATO TÉCNICO:`, `UPDATE:` — these confuse the extractor
   - **No before/after narratives** — state only the CURRENT fact
   - **One fact = one sentence or two.** If you need a comma-separated list, keep it under 3 items
   - **Under 300 chars.** Shorter = cleaner extraction
   - **Plain language.** Write as if explaining to a colleague, not documenting for audit

2. **Still `facts: []`?** → Split into even smaller atomic facts:

   ```
   FAILED: "Formulário tem maxlength nos campos: name 100, email 254, subject 200, message 5000.
   Validação server-side duplicada no CloudFlare Worker."

   RETRY AS TWO SAVES:
   Save A: "Campos do formulário Fale Conosco têm maxlength: name 100, email 254, subject 200, message 5000."
   Save B: "CloudFlare Worker em functions/api/contact.js valida os mesmos limites server-side."
   ```

3. **Still `facts: []` after splitting?** → **Fallback to workspace.** The knowledge extraction pipeline is not processing this content. Save via `cipher_workspace_store` instead, which uses a different extraction pipeline and accepts structured `workspaceInfo`:
   ```json
   {
     "interaction": "Same content that failed in knowledge",
     "options": { "similarityThreshold": 0.95 },
     "workspaceInfo": {
       "currentProgress": {
         "feature": "description",
         "status": "completed",
         "completion": 100
       },
       "bugsEncountered": [
         { "description": "...", "severity": "high", "status": "fixed" }
       ]
     }
   }
   ```
   **Report to user:** "Knowledge extraction failed after 3 attempts. Saved via workspace as fallback. Information is searchable via cipher_workspace_search. Recommend investigating Cipher knowledge pipeline."

**Maximum attempts: 3 (simplify → split → fallback).** After fallback, STOP. Do NOT retry knowledge.

**IMPORTANT:** The workspace fallback is a LAST RESORT, not a routine alternative. Knowledge and workspace serve different purposes and are searched separately. Using workspace for technical facts means those facts won't appear in `cipher_memory_search` results. Always attempt knowledge first with proper atomic format.

## Session Save Workflow ("Salve o progresso")

When asked to save session progress, follow this complete workflow:

1. **Inventory**: List all decisions, discoveries, bugs, and progress from this session
2. **Classify** each item by type (technical → knowledge, progress → workspace, reasoning → reflection)
3. **Pre-flight search** for each item in the MATCHING collection
4. **Save items one at a time**, verifying each response before proceeding
5. **On failure**: Check significance filter first (if ALL fail), then follow Step 5 (dedup) or Step 6 (extraction) depending on the failure type
6. **Summary report** to user:
   ```
   Saved: 4/5 items
   - [knowledge] Redis TTL decision → SUCCESS
   - [knowledge] API endpoint pattern → SUCCESS
   - [workspace] Sprint progress → SUCCESS
   - [workspace] Bug #42 documentation → SUCCESS
   - [knowledge] Auth flow decision → SKIPPED (already existed from session 03-10)
   ```
   If any item used workspace fallback:
   ```
   - [knowledge→workspace fallback] CF Worker architecture → SUCCESS via workspace
     (knowledge extraction failed — search via cipher_workspace_search)
   ```

**Never say "tudo salvo" without verifying each item individually.**

## Updating Existing Memories

Only `cipher_extract_and_operate_memory` supports UPDATE/DELETE (LLM auto-decides). `cipher_workspace_store` is append-only.

Frame updates with explicit change context — state the current fact directly, the LLM auto-decides ADD vs UPDATE based on existing entries:

```json
{
  "interaction": "Redis cache TTL é 2h na API de agendamento. Motivo: cache miss rate de 45% em horário de pico.",
  "options": { "similarityThreshold": 0.95 }
}
```

## Cognitive Interrupt — Check Before EVERY Save

Before each save call, pause and verify these 4 things:

1. **Right tool?** Technical → `extract_and_operate_memory`. Progress → `workspace_store`. Reasoning → `store_reasoning_memory`.
2. **Threshold included?** `options.similarityThreshold: 0.95` present? (not for reasoning)
3. **Pre-flight done?** Did I search first to know what already exists?
4. **Atomic format?** Is the `interaction` under 500 chars, prefix-free, and stating a direct fact? (for knowledge saves)

If any answer is NO, fix it before calling the save tool.

## Red Flags — STOP IMMEDIATELY

If you catch yourself saying or thinking ANY of these, you are off-protocol:

| Rationalization                                     | Protocol Response                                                                                                                                  |
| --------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| "Cipher continua pulando..."                        | Did you pass `similarityThreshold: 0.95`? If ALL saves fail, check significance filter patch.                                                      |
| "Vou tentar com conteúdo mais específico..."        | **NO.** Search first. Then use structural prefix, not reformulation.                                                                               |
| "Vou reformular/reescrever..."                      | **FORBIDDEN.** Reformulation = unpredictable embedding changes. Prefix only (for dedup). Atomic simplification only (for extraction).              |
| "Vou usar a outra tool como alternativa..."         | **NO** — unless you are in Step 6.3 (extraction fallback to workspace after 3 failures).                                                           |
| "O Cipher está sendo muito agressivo..."            | **NO.** Check threshold param. Then check if `facts: []` (extraction) or `skipped: 1` (dedup). If ALL saves fail, check significance filter patch. |
| "Vou repetir com texto mais distinto..."            | **NO.** Follow Step 5 (dedup) or Step 6 (extraction) exactly.                                                                                      |
| "Cipher está pulando incorretamente..."             | Are you searching the RIGHT collection? If ALL saves fail, check significance filter patch.                                                        |
| "Vou salvar de qualquer jeito..."                   | **NO.** Max 3 attempts per step. After that, report to user.                                                                                       |
| "Tudo salvo!" (without verification)                | **NO.** Verify each item's response individually.                                                                                                  |
| "Vou adicionar mais contexto para o LLM extrair..." | **NO.** More text = worse extraction. SIMPLIFY, don't expand.                                                                                      |
| "Vou consolidar tudo num único save..."             | **NO.** More topics per save = diluted embedding + harder extraction. Split, don't merge.                                                          |

## Common Mistakes

| Mistake                                      | Why It Fails                                                   | Do Instead                                                  |
| -------------------------------------------- | -------------------------------------------------------------- | ----------------------------------------------------------- |
| Save without pre-flight search               | Blindly hitting dedup                                          | Search first, then save with awareness                      |
| Retry same content                           | Same embedding = same skip                                     | Structural prefix `[Project][Date]` or verify already saved |
| Switch workspace_store → extract_and_operate | Different collections, wrong search                            | Use correct tool for content type                           |
| Say "tudo salvo" without checking responses  | Some saves silently skipped                                    | Verify each response: `extracted >= 1`                      |
| Pass threshold to reasoning memory           | Silently ignored                                               | Use `shouldStore: true` instead                             |
| Save multiple topics in one call             | Embedding diluted, poor retrieval                              | One topic per save                                          |
| Exceed 3 recovery attempts                   | Same result, wasted time                                       | Stop and report to user                                     |
| Use decorative prefixes in knowledge saves   | `[PROJECT][DATE]` confuses LLM extractor → `facts: []`         | Plain atomic statements, no prefixes                        |
| Write narrative before/after comparisons     | LLM extractor can't parse multi-fact narratives                | State only the current fact, one fact per save              |
| Add MORE context when extraction fails       | Longer text = worse extraction                                 | SIMPLIFY to under 300 chars                                 |
| Consolidate multiple items into one save     | Embedding diluted + extractor confused                         | One topic, one fact, one save                               |
| Confuse dedup skip with extraction failure   | `skipped: 1` ≠ `facts: []` — different causes, different fixes | Check response: skipped → Step 5, facts:[] → Step 6         |
| Ignore ALL saves failing                     | Significance filter patch may be lost                          | Check patch status before retrying individual saves         |

## Parameter Cheat Sheet

### cipher_extract_and_operate_memory

```json
{
  "interaction": "One atomic fact in plain language, under 300 chars ideal",
  "options": { "similarityThreshold": 0.95 }
}
```

Default threshold: **0.6** — always override to 0.95. Supports ADD/UPDATE/DELETE (auto-decided).

**Atomic format rules:**

- No prefixes (`[PROJECT]`, `FATO TÉCNICO:`, `UPDATE:`)
- One fact per save
- Under 300 chars ideal, max 500
- State current fact only (no before/after)
- Plain language (no jargon decorations)

### cipher_workspace_store

```json
{
  "interaction": "Session progress or status update",
  "options": { "similarityThreshold": 0.95 },
  "workspaceInfo": {
    "currentProgress": {
      "feature": "X",
      "status": "completed",
      "completion": 100
    },
    "bugsEncountered": [
      { "description": "...", "severity": "high", "status": "fixed" }
    ]
  }
}
```

Default threshold: **0.8** — always override to 0.95. Append-only. Structured `workspaceInfo` improves extraction accuracy.

### cipher_store_reasoning_memory

```json
{
  "trace": {
    "id": "unique-id",
    "steps": [{ "type": "decision", "content": "..." }],
    "metadata": {
      "extractedAt": "ISO",
      "stepCount": 1,
      "conversationLength": 1,
      "hasExplicitMarkup": false
    }
  },
  "evaluation": {
    "qualityScore": 0.8,
    "shouldStore": true,
    "issues": [],
    "suggestions": []
  }
}
```

**No similarity dedup.** No `options` parameter. Skip only if `qualityScore` < 0.3 or `shouldStore: false`.

## Quick Diagnosis: Why Did My Save Fail?

| Response                                 | Cause                                            | Go to                            |
| ---------------------------------------- | ------------------------------------------------ | -------------------------------- |
| ALL saves return `extracted: 0`          | Significance filter patch lost                   | Reapply patch (see top of skill) |
| `extracted: 0, skipped: 1` (single save) | Dedup — content too similar to existing entry    | Step 5                           |
| `extracted: 0, facts: []` (single save)  | Extraction — LLM could not parse facts from text | Step 6                           |
| `extracted: 0` (no skipped, no facts)    | Likely extraction failure                        | Step 6                           |
| `stored: false, quality_threshold`       | Reasoning quality too low                        | Set `qualityScore > 0.3`         |
| `stored: false, validationErrors`        | Missing required fields in trace                 | Check error message              |

## Debug Logging

To enable detailed logs for troubleshooting:

1. **Env var:** `CIPHER_LOG_LEVEL=debug` must be in the MCP env block in `~/.claude.json`
2. **Log location:** `/tmp/cipher-mcp.log`
3. **Key debug messages:**
   - `Skipping non-significant fact` → significance filter blocked (patch lost)
   - `No significant facts found after filtering` → all content blocked (patch lost)
   - `Skipping non-workspace-significant content` → workspace filter blocked (patch lost)
   - `ExtractAndOperateMemory:` followed by embedding/LLM logs → normal operation

## Limits

| Max chars/call | Max tokens/embedding | Sweet spot                                            | Embeddings rate |
| -------------- | -------------------- | ----------------------------------------------------- | --------------- |
| 32,768         | 8,191                | 200-300 chars (knowledge) / 200-500 chars (workspace) | 200 req/min     |

For content exceeding the sweet spot, split at semantic boundaries (one decision, one bug, one pattern per save).
