# Cipher Significance Filter Fix

Root cause analysis, community fix, and a Claude Code skill born from a silent data loss bug in [Cipher](https://github.com/campfirein/cipher) (Byterover) v0.3.0 that caused MCP memory operations to silently discard content. The bug was open for ~6 months before being identified and resolved.

This repository contains the full investigation, the patch, and a Claude Code skill that was born from the experience.

## Timeline

| Date         | Event                                                                                                                     |
| ------------ | ------------------------------------------------------------------------------------------------------------------------- |
| Sep 26, 2025 | [Issue #263](https://github.com/campfirein/cipher/issues/263) opened -- MCP mode does not store data in Qdrant            |
| Oct 15, 2025 | [Issue #275](https://github.com/campfirein/cipher/issues/275) opened -- MCP timeout with RooCode (likely same root cause) |
| Nov 5, 2025  | A user falsely claims the repo is archived; no fix in sight                                                               |
| Mar 13, 2026 | Root cause identified and [published on #263](https://github.com/campfirein/cipher/issues/263#issuecomment-4057453293)    |
| Mar 16, 2026 | [PR #296](https://github.com/campfirein/cipher/pull/296) merged -- `DISABLE_SIGNIFICANCE_FILTER` env var added            |
| Mar 16, 2026 | Issue #263 closed as completed                                                                                            |
| Mar 27, 2026 | Issue #275 closed, referencing the significance filter bypass                                                             |

---

## The Problem

Cipher v0.3.0 has a memory persistence layer that uses vector embeddings (Qdrant, ChromaDB, etc.) to store and retrieve knowledge. When running as an MCP server (the standard integration mode for AI coding agents like Claude Code), all `cipher_extract_and_operate_memory` calls returned:

```
extracted: 0, skipped: 1
```

The tool reported success (`success: true`) but stored nothing. No error, no warning, no indication of what went wrong. The response was identical to a legitimate deduplication skip, making diagnosis extremely difficult.

Multiple users reported the issue across different setups (Gemini API, OpenAI, AWS Bedrock, LM Studio), different vector stores, and different MCP clients (Claude Code, RooCode). The common thread: data sent via MCP was silently dropped.

## The Investigation

After exhausting the obvious suspects (API keys, Qdrant connectivity, dedup thresholds, content format, LLM configuration), I enabled debug logging:

```bash
# Added to MCP env block in ~/.claude.json
"CIPHER_LOG_LEVEL": "debug"
```

The debug logs in `/tmp/cipher-mcp.log` revealed what the tool responses never showed:

```
ExtractAndOperateMemory: Skipping non-significant fact
ExtractAndOperateMemory: No significant facts found after filtering
```

Content was being discarded **before** any embedding, LLM processing, or deduplication.

The full root cause analysis was [published on Issue #263](https://github.com/campfirein/cipher/issues/263#issuecomment-4057453293).

## Root Cause

Cipher has two hardcoded heuristic functions that run as the first step in the memory pipeline:

- `isSignificantKnowledge(content)` -- filters knowledge memory saves
- `isWorkspaceSignificantContent(content)` -- filters workspace memory saves

These functions use regex-based `skipPatterns` to classify content as "non-significant":

```javascript
const skipPatterns = [
  /\b(my name|user['']?s? name|find my name|search.*name|who am i|what['']?s my name)\b/i,
  /\b(personal|profile|identity|username|login|password|email|address|phone)\b/i,
  // ...
];
```

The word **`email`** in the second pattern causes all content mentioning email -- email endpoints, email fields, email APIs, email sending services -- to be classified as "personal information" and silently discarded. The same applies to `address` (IP addresses, memory addresses), `login` (authentication systems), `password` (password hashing, validation), and `phone` (telephony APIs).

Additionally, content that passes `skipPatterns` must then match `technicalPatterns` -- a whitelist of English programming terms. Non-English technical content (Portuguese, Russian, French, etc.) often fails this check regardless of its actual significance.

The filter runs at line ~23226 of `dist/src/core/index.cjs` and line ~25937 of `dist/src/app/index.cjs`.

### Why it took 6 months

1. The filter response (`extracted: 0, skipped: 1`) is **identical** to a dedup skip. There is no way to distinguish them without debug logs.
2. The `success: true` field in the response misleads the caller into thinking the operation succeeded.
3. The filter runs before embedding, before the LLM, and before dedup -- so all standard troubleshooting (API keys, thresholds, content format) leads nowhere.
4. `workspace_store` uses a different extraction pipeline with structured `workspaceInfo`, so it worked intermittently even when `extract_and_operate_memory` always failed. This inconsistency complicated diagnosis further.

## The Fix

### The fix (PR #296)

Three days after the root cause was published, maintainer [@RyanNg1403](https://github.com/RyanNg1403) submitted and merged [PR #296](https://github.com/campfirein/cipher/pull/296), adding a `DISABLE_SIGNIFICANCE_FILTER=true` environment variable to bypass the filter. The fix directly references the investigation:

```bash
# Add to your MCP env block or .env
DISABLE_SIGNIFICANCE_FILTER=true
```

### Original workaround (before PR #296)

Before the official fix was available, the workaround was to patch the source directly:

```bash
CIPHER_CORE="$(dirname $(which cipher))/../lib/node_modules/@byterover/cipher/dist/src/core/index.cjs"
CIPHER_APP="$(dirname $(which cipher))/../lib/node_modules/@byterover/cipher/dist/src/app/index.cjs"

cp "$CIPHER_CORE" "$CIPHER_CORE.bak"
cp "$CIPHER_APP" "$CIPHER_APP.bak"

sed -i 's/function isSignificantKnowledge(content) {/function isSignificantKnowledge(content) { return true;/' "$CIPHER_CORE"
sed -i 's/function isSignificantKnowledge(content) {/function isSignificantKnowledge(content) { return true;/' "$CIPHER_APP"
sed -i 's/function isWorkspaceSignificantContent(content) {/function isWorkspaceSignificantContent(content) { return true;/' "$CIPHER_CORE"
sed -i 's/function isWorkspaceSignificantContent(content) {/function isWorkspaceSignificantContent(content) { return true;/' "$CIPHER_APP"
```

After patching: `extracted: 1, confidence: 0.95` -- knowledge memory works correctly.

## Community Impact

The root cause analysis on issue #263 directly led to:

- **[PR #296](https://github.com/campfirein/cipher/pull/296)** merged (Mar 16, 2026) -- official fix with env var bypass
- **[Issue #263](https://github.com/campfirein/cipher/issues/263)** closed as completed after ~6 months open
- **[Issue #275](https://github.com/campfirein/cipher/issues/275)** closed, with the maintainer noting the significance filter as likely cause of the MCP timeout loop

### Maintainer acknowledgment

The PR body credits the investigation:

> Root cause analysis by @MafraAiDev in #263.
>
> @MafraAiDev confirmed the significance filter as root cause (Qdrant + OpenAI) -- this fix directly addresses that

![PR #296 body -- maintainer credits the root cause analysis and lists affected users by setup](assets/pr-296-mention.png)

The maintainer also referenced the finding when responding to the separate timeout issue (#275):

> Another user (@MafraAiDev in #263) found that the memory significance filter silently rejects content containing common terms like "email", "address", etc., causing the agent to retry in a loop until it hits max iterations.

![Issue #275 -- maintainer @RyanNg1403 links the timeout to the significance filter found in #263](assets/issue-275-mention.png)

The full issue #263 thread shows the complete arc: original report (Sep 2025), multiple reporters with different setups, the root cause comment (Mar 13, 2026), and the closure events (commit, PR merged, closed as completed):

![Issue #263 -- full thread from original report through root cause analysis to closure](assets/issue-263-full.png)

> **Note on GitHub username:** `@MafraAiDev` was my previous GitHub username. My current account is [@ThiagoMafra-Integrare](https://github.com/ThiagoMafra-Integrare).

## The Skill: cipher-memory-expert

The investigation produced a Claude Code skill ([`skill/SKILL.md`](skill/SKILL.md)) that encodes everything learned into a deterministic protocol for Cipher memory operations. The skill:

- Defines a fixed save protocol with threshold overrides (`similarityThreshold: 0.95`)
- Distinguishes between dedup skips (`skipped: 1`) and extraction failures (`facts: []`)
- Documents the three separate memory systems and their search/save tool pairs
- Includes a pre-flight check to search before saving
- Provides step-by-step recovery sequences for both dedup and extraction failures
- Contains the full significance filter patch with diagnosis and reapply instructions

The skill is designed to be dropped into any Claude Code project directory as a reusable skill file.

### How to use the skill

Copy `skill/SKILL.md` to your Claude Code skills directory:

```bash
mkdir -p ~/.claude/skills/cipher-memory-expert
cp skill/SKILL.md ~/.claude/skills/cipher-memory-expert/SKILL.md
```

Or reference it in your project's `.claude/settings.json`.

## Repository Contents

```
cipher-significance-filter-fix/
├── README.md                       # This file
├── LICENSE                         # MIT
├── assets/
│   ├── pr-296-mention.png          # PR #296 body crediting the root cause analysis
│   ├── issue-275-mention.png       # Maintainer referencing the analysis in #275
│   └── issue-263-full.png          # Full issue thread: report, analysis, closure
├── skill/
│   └── SKILL.md                    # Claude Code skill: cipher-memory-expert
└── docs/                           # Investigation documentation (pt-BR)
    ├── investigation-report.md     # Full investigation report (Mar 13, 2026)
    ├── setup-guide.md              # Cipher + Qdrant WSL2 setup guide
    ├── per-project-guide.md        # Per-project Cipher usage protocol
    └── initial-setup-report.md     # Initial configuration report (Feb 25, 2026)
```

> Investigation documentation is written in Brazilian Portuguese (pt-BR), as that was the working language during the investigation.

## Links

- **Cipher repository:** [campfirein/cipher](https://github.com/campfirein/cipher)
- **The issue:** [#263 -- MCP server does not store data in Qdrant](https://github.com/campfirein/cipher/issues/263)
- **The fix:** [PR #296 -- add DISABLE_SIGNIFICANCE_FILTER env var](https://github.com/campfirein/cipher/pull/296)
- **Related issue:** [#275 -- MCP Timeout with RooCode](https://github.com/campfirein/cipher/issues/275)
- **My comment with root cause analysis:** [#263 comment](https://github.com/campfirein/cipher/issues/263#issuecomment-4057453293)

## License

MIT
