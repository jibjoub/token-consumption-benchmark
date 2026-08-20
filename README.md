# token-consumption-benchmark

Benchmark measuring **token cost and answer accuracy of a Claude Code agent** answering read-only code-comprehension questions about a repository, **with vs. without** the CAST Imaging MCP server (structural/transactional code-analysis tools) available to it.

> **Scope note:** This is a standalone measurement tool. It does not go through Orbit Planner's `web-test01` / `mcp-test01` / `llm-test01` flow — it drives the `claude` CLI directly against an arbitrary target repo (the sample target used so far is CAST's "Recipe" sample app). Don't conflate its cost numbers with Orbit's own dashboard metrics.

## Purpose

CAST Imaging exposes an MCP server with tools for structural/transaction analysis of a codebase (call graphs, impacted tables, impacted pages, etc.). The question this benchmark answers is:

- **Does giving Claude Code access to those tools change answer accuracy and/or token cost**, compared to Claude reading the source directly?
- When CAST *is* available, **does Claude actually choose to use it**, or does it fall back to grepping the repo anyway?
- When Claude is explicitly told to use CAST, **how good is the result**, independent of whether it would have reached for the tool on its own?

Answering this requires running the *same* question many times per condition (LLM output is non-deterministic) and logging cost/tokens/tool-usage/correctness for every single run — that's what this repo automates.

## How it works — pipeline

```
bench-questions.json --> run-benchmark.ps1 --> results.jsonl --> score-results.py --> scores.jsonl
                                                       |
                                                       +--> analyze-results.py (console summary)
```

### 1. [`bench-questions.json`](bench-questions.json) — the questions
Each entry has:
- `id` — short identifier used everywhere else (results, filtering via `-QuestionIds`).
- `prompt` — the read-only question asked of the agent (e.g. "count and list all DB tables impacted by a change to `editrecipe.aspx`").
- `json_schema` *(optional)* — a JSON Schema forcing the answer into a structured object instead of free text, via `claude -p --json-schema`.
- `expected` *(optional)* — ground truth used by `score-results.py` for automatic scoring.

### 2. [`run-benchmark.ps1`](run-benchmark.ps1) — the runner
For every question and every requested **condition**, it invokes `claude -p` `N` times (`-Runs`) against the target repo and appends one JSON record per run to `results.jsonl`. Each run is a brand-new, history-free session.

Three conditions:

| Condition | CAST MCP loaded? | Behavior |
|---|---|---|
| `without` | No | Baseline — Claude must read source directly. |
| `with` | Yes | Claude decides on its own whether to call CAST ("revealed preference"). |
| `with-forced` | Yes | Same prompt + an explicit instruction telling Claude to use CAST. |

`with` and `without` are the default (`-Conditions without,with`); add `with-forced` explicitly when needed. Keep all three around rather than picking one — real runs have shown `with` calling CAST anywhere from 3/5 to 5/5 times on an identical prompt, so "available" ≠ "used", and `with-forced` isolates "how good is CAST's answer" from "does Claude bother reaching for it".

Each result record includes: `cost_usd`, `num_turns`, `input_tokens`/`output_tokens`/`cache_creation_tokens`/`cache_read_tokens`, `model_usage` (per-model cost breakdown), `tools_used` (every tool actually called), `used_mcp_tool` (true iff a `mcp__CASTImaging__*` tool was called), `structured_output` (when the question used `json_schema`), the raw `result` text, `session_id`, and an empty `correct` field for manual grading of free-text questions.

### 3. [`score-results.py`](score-results.py) — automatic scoring
For any question that has both an `expected` field and a `structured_output` result, joins `results.jsonl` against `bench-questions.json` and computes, per run:
- **`acc`** (recall) — fraction of the true answer set that was found.
- **`noise`** — fraction of the found set that wasn't actually true (invented/extra items).
- **`exact_match`** — found set == expected set exactly.

Path-like values (`.aspx` pages) are matched by basename so a dropped/added directory prefix isn't double-penalized as both a miss and an extra. Writes a separate, fully recomputable **[`scores.jsonl`](scores.jsonl)** — re-run any time `results.jsonl` or `bench-questions.json` changes.

Free-text questions (no `json_schema`/`expected`) aren't scored here — they need manual `correct: true/false` grading directly in `results.jsonl`.

```
python score-results.py results.jsonl [bench-questions.json] [--out scores.jsonl]
```

### 4. [`analyze-results.py`](analyze-results.py) — console summary
Groups `results.jsonl` by `(app, question_id, condition)` and prints median cost, median total tokens, accuracy (from hand-filled `correct` fields), and CAST usage rate.

```
python analyze-results.py results.jsonl
```

## Prerequisites

- **Windows PowerShell 7.3+** (`pwsh`), not Windows PowerShell 5.1. Below 7.3, argument passing to the underlying `claude.ps1` → `node` hop mangles arguments full of embedded quotes — which is exactly what a `--json-schema` argument is. `run-benchmark.ps1` warns once at startup if it detects a schema-bearing question on an old PowerShell version. Alternative: `claude install` to switch from the npm shim to the native build, which removes the extra hop entirely.
- **Claude Code CLI** (`claude`) installed and logged in (normal OAuth/subscription login — no API key required; the script does not use `--bare`).
- **Python 3** (standard library only, no `pip install` needed) for `score-results.py` / `analyze-results.py`.
- A local checkout of the **target repository** to benchmark.
- A **CAST Imaging MCP config file** (see [`cast.json`](cast.json)) for `with`/`with-forced` runs, pointing at a running CAST Imaging server with the target app registered.

## Running it

```powershell
# First pass: a small app, one question, 5 reps per condition (without, with)
.\run-benchmark.ps1 `
    -RepoPath "C:\path\to\recipe-main\recipe-main" `
    -AppName "recipe" `
    -Runs 5

# Bigger app later, same shared results file (so analyze-results.py can
# build one cross-app comparison table)
.\run-benchmark.ps1 `
    -RepoPath "C:\path\to\bigger-app" `
    -AppName "bigger-app" `
    -McpConfigPath "C:\path\to\bigger-app\cast.json" `
    -Runs 5

# Add more samples to just one condition
.\run-benchmark.ps1 -RepoPath ... -AppName recipe -Conditions without -Runs 10

# Single question, all three conditions, a specific model, its own results file
.\run-benchmark.ps1 -RepoPath ... -AppName recipe `
    -QuestionIds table-count -Model haiku `
    -Conditions without,with,with-forced -Runs 10 `
    -ResultsFile .\results-haiku.jsonl

# Tell Claude which application to search for INSIDE CAST Imaging
# (this is NOT the same as -AppName -- see "Parameters" below)
.\run-benchmark.ps1 -RepoPath ... -AppName recipe `
    -CastImagingAppName "Recipe" -Conditions with,with-forced -Runs 10
```

Then, after the run(s):

```powershell
python score-results.py results.jsonl bench-questions.json
python analyze-results.py results.jsonl
```

For free-text questions (no `expected`/`json_schema`), open `results.jsonl`, read each run's `result` field against the ground truth by hand, and fill in `correct: true`/`false` before running `analyze-results.py`.

### Key parameters

| Parameter | Default | Meaning |
|---|---|---|
| `-RepoPath` *(required)* | — | Target repo to benchmark against. |
| `-AppName` *(required)* | — | Label for grouping rows in the results file. Never sent to Claude. |
| `-QuestionsFile` | `bench-questions.json` | Question set. |
| `-McpConfigPath` | `<RepoPath>\cast.json` | MCP config for `with`/`with-forced`. |
| `-ResultsFile` | `results.jsonl` | Where to append records. Point different models at different files, or rely on the logged `model` field — both are now safe (see below). |
| `-Runs` | `5` | Repetitions per (question, condition). |
| `-Conditions` | `without,with` | Any of `without`, `with`, `with-forced`. |
| `-QuestionIds` | *(all)* | Restrict to specific question ids. |
| `-Model` | *(CLI default)* | Claude Code model alias/ID (`haiku`, `sonnet`, `opus`, or a dated ID). Verify it resolves first with a throwaway `claude --model haiku -p "hi"`. |
| `-CastImagingAppName` | *(none)* | Application name **inside CAST Imaging itself** to search — distinct from `-AppName`, which is just this script's own label. Only injected into the prompt on `with`/`with-forced` runs. |
| `-BaseAllowedTools` | `Read,Grep,Glob,Bash(git *),Bash(ls *),Bash(find *)` | Tool allowlist. Read-only by design — no `Edit`/`Write`, so Claude cannot modify the target repo. `mcp__CASTImaging__*` is added automatically for `with`/`with-forced`. |
| `-ForceInstruction` | *(built-in text)* | Instruction appended verbatim to the question prompt on `with-forced` runs. |

## Important gotchas (read before trusting numbers)

- **Auto-memory contamination (fixed, but know why).** Claude Code's auto-memory is scoped to the git repo, not the session — every `claude` call with `cwd` inside `-RepoPath` reads/writes the same `~/.claude/projects/<project>/memory/` directory regardless of `--continue`/`--resume`. A real incident: a `with-forced` run saved its answer to memory, and later `without` runs (which never load CAST) auto-loaded that memory and reported it back as if independently derived — Haiku `without` accuracy jumped from a stuck 50% to 100% "for free" the moment this happened. **Fix already applied**: the script sets `$env:CLAUDE_CODE_DISABLE_AUTO_MEMORY = "1"` before every `claude` call. If you're auditing older data, check whether it predates this fix, and if so, whether `~/.claude/projects/<project>/memory/` was cleared before those runs.
- **Tool search is forced off** (`$env:ENABLE_TOOL_SEARCH = "false"`) so CAST's tool definitions are visible from turn one on `with`/`with-forced` runs, rather than requiring Claude to proactively discover them first — otherwise a "Claude didn't use CAST" result could mean "never found it exists" rather than "chose not to".
- **Prompt cache is shared across runs and is NOT a bug.** It can make a run cheaper (not smarter) if a prior run already cached identical content within the cache TTL. `cache_creation_tokens`/`cache_read_tokens` are logged separately precisely so this shows up as a visible cost confound instead of silently distorting a blended number.
- **`with-forced` is a strong instruction, not a guarantee.** There's no CLI equivalent of the API's `tool_choice` to force MCP tool use mechanically — always check `used_mcp_tool` on `with-forced` rows too.
- **Structured output (`--json-schema`) is not free**: it adds roughly one extra turn and a small extra cost, and can suppress prose reasoning. Treat `used_json_schema` as its own cohort — don't average a schema-on row against a schema-off row for the same `question_id`.
- **Model mixing is safe now**, but keep it deliberate: `results.jsonl` rows carry a `model` field (`"default"` when `-Model` is unset), and both scoring scripts group by it — so a mixed file produces model-pure groups instead of a blended median. Rows predating this field have no `model` key at all and are normalized to `"default"`.

## Files in this repo

| File | Role |
|---|---|
| [`bench-questions.json`](bench-questions.json) | Question definitions + ground truth. |
| [`run-benchmark.ps1`](run-benchmark.ps1) | Runner — drives `claude -p`, writes `results.jsonl`. |
| [`score-results.py`](score-results.py) | Automatic scoring against ground truth → `scores.jsonl`. |
| [`analyze-results.py`](analyze-results.py) | Console summary table from `results.jsonl`. |
| [`results.jsonl`](results.jsonl) | Append-only observation log (default model). |
| [`results-haiku.jsonl`](results-haiku.jsonl) | Same, for a dedicated Haiku run. |
| [`scores.jsonl`](scores.jsonl) | Derived, recomputable scoring output. |
| [`cast.json`](cast.json) | Sample CAST Imaging MCP config (`--mcp-config`) for the target repo. |
| [`cast_force_test.json`](cast_force_test.json) / [`extract.json`](extract.json) | Ad hoc sample outputs from earlier manual test runs (not consumed by the pipeline). |

## ⚠️ Security note

[`cast.json`](cast.json) contains a live CAST Imaging API key (`x-api-key`) in plain text. If this repo is or will be pushed anywhere shared, treat that key as exposed: rotate it and/or exclude the file via `.gitignore`, and pass a local, untracked config path via `-McpConfigPath` instead.
