<#
CAST Imaging MCP benchmark runner
==================================

Purpose
  Run the same read-only question against a repo, with and without the CAST
  Imaging MCP server loaded, N times each, and log token/cost usage so the
  two conditions can be compared.

  Designed for reuse across apps: point -RepoPath at a different repo and
  give it a different -AppName, but keep pointing -ResultsFile at the same
  shared file. Every app's runs land in one JSONL, so analyze-results.py can
  build a single cross-app comparison table -- start small on one app, then
  scale to bigger ones without changing anything else.

  Nothing in the allowed tool set includes Edit or Write, so Claude cannot
  modify the repo even if it wanted to. This phase is read-only by design,
  which is also why no git reset/checkout step is needed between runs --
  there is nothing for a run to leave behind that could contaminate the next
  one.

  No cross-run memory: every "claude -p" call below starts a brand-new,
  history-free session (no --continue/--resume is ever passed -- do not add
  either flag to this script, that is the one thing that would actually let
  one run's SESSION leak into the next).

  CORRECTION (2026-08-18): the claim that used to be here -- "no-continue/
  no-resume guarantees no memory carries over" -- is wrong, and a real
  contamination incident proved it. Claude Code's auto memory feature is on
  by default and is scoped to the git repo, not the session: every session
  that runs with cwd inside $RepoPath reads and writes the SAME
  ~/.claude/projects/<project>/memory/ directory, regardless of --continue/
  --resume. A "with-forced" run that genuinely calls CAST can save its
  answer there, and every later run -- including "without", which never
  loads CAST at all -- gets that answer auto-loaded into context and can
  just report it back as if it were independently derived. This is exactly
  what happened to a batch of Haiku table-count runs: "without" runs that
  had capped at 50% accuracy for two straight days suddenly started
  scoring 100%, for free, the moment a with-forced run's memory note landed.
  See the memory files themselves for the confession: each one has an
  `originSessionId` in its frontmatter pointing straight at the with-forced
  session that wrote it.

  THE FIX: set $env:CLAUDE_CODE_DISABLE_AUTO_MEMORY = "1" before every
  `claude` invocation (already done below, right after Push-Location). This
  is the surgical fix -- it disables exactly the mechanism that leaked,
  works with normal OAuth/subscription login (no API key needed), and
  doesn't touch hooks/skills/plugins/CLAUDE.md the way --bare would.
  One-time cleanup still required: this only stops NEW contamination, it
  doesn't erase what's already in ~/.claude/projects/<project>/memory/ from
  before this fix landed -- delete that directory once (see below) before
  trusting any further runs.

  Note on --bare: it also skips auto-loading hooks, skills, plugins,
  auto-memory, and CLAUDE.md, which would be a blunter, more total version
  of the fix above -- but it ALSO skips OAuth/keychain reads, so it only
  works if ANTHROPIC_API_KEY is set. If you're logged into `claude`
  normally (OAuth, e.g. a Claude subscription), --bare will fail with "Not
  logged in". This script does NOT use --bare for that reason; disabling
  auto memory specifically (above) gets the guarantee that actually matters
  without needing an API key. If you do have an API key and want the extra
  isolation anyway, set $env:ANTHROPIC_API_KEY and add "--bare" back into
  $claudeArgs below.

  The one thing that IS shared across runs, and is not a bug: Anthropic's
  prompt cache. It can make a run cheaper (not smarter) if an earlier run
  within the cache TTL already paid to cache identical content (system
  prompt, tool schemas, file contents). That is a cost confound, not an
  answer leak -- cache_creation_tokens and cache_read_tokens are logged
  separately below precisely so you can see it in the data rather than have
  it silently distort a blended number.

Usage
  # First pass: the small app, one question, 5 reps per condition
  .\run-benchmark.ps1 `
      -RepoPath "C:\Users\JBD\Desktop\CAST\Applications to analyze\recipe-main\recipe-main" `
      -AppName "recipe" `
      -Runs 5

  # Later: same script, a bigger app, same shared results file
  .\run-benchmark.ps1 `
      -RepoPath "C:\path\to\bigger-app" `
      -AppName "bigger-app" `
      -McpConfigPath "C:\path\to\bigger-app\cast.json" `
      -Runs 5

  # Just the "without CAST" condition (e.g. to add more samples later)
  .\run-benchmark.ps1 -RepoPath ... -AppName recipe -Conditions without -Runs 10

  # Same table-count question only, on Haiku instead of the default model,
  # all three conditions, written to its own results file so Haiku's numbers
  # never get blended into the default-model file by accident:
  .\run-benchmark.ps1 -RepoPath ... -AppName recipe `
      -QuestionIds table-count -Model haiku `
      -Conditions without,with,with-forced -Runs 10 `
      -ResultsFile .\results-haiku.jsonl

  # Tell Claude which application to search for inside CAST Imaging itself
  # (the CAST Imaging application name, not -AppName -- see "CAST Imaging
  # application name" below for why these are two different things):
  .\run-benchmark.ps1 -RepoPath ... -AppName recipe `
      -CastImagingAppName "Recipe" -Conditions with,with-forced -Runs 10

Output
  Appends one JSON object per run to -ResultsFile (JSONL, default
  .\results.jsonl next to this script). Fields: app, question_id, condition,
  run_index, cost_usd, num_turns, token breakdown, the raw result text, and
  an empty "correct" field for you to hand-fill (true/false) after reading
  the result against the ground truth -- analyze-results.py picks that up
  automatically if present.

  Also records tools_used (every tool name Claude actually called, built-in
  or MCP) and used_mcp_tool (true only if one of those names matches
  mcp__CASTImaging__*). --mcp-config only makes the server AVAILABLE; since
  the prompt is identical across conditions and Claude decides on its own
  whether to reach for it, a "with" run that never actually calls a CAST
  tool is a real possible outcome, not a bug -- these two fields let you see
  that directly in the data instead of having to dig through a session
  transcript by hand after the fact whenever a result looks suspicious.
  Getting this requires switching from --output-format json to
  --output-format stream-json, which emits one line per event (including
  each tool call) instead of just the final answer -- see the parsing loop
  below.

  Tool search is forced OFF ($env:ENABLE_TOOL_SEARCH = "false") for every
  run, both conditions. By default Claude Code withholds MCP tool
  definitions from context and only loads them once Claude proactively
  searches and finds them -- so a "with" run can fail to use CAST not
  because Claude weighed it and chose the SQL file instead, but because it
  never thought to search for it in the first place (this is literally what
  happened on an early Recipe run: the transcript showed CAST's tools
  entering the searchable pool but never being searched for or called).
  CAST's tool count is well under the ~10-tool point where the docs say
  loading everything upfront is faster anyway, so disabling search just
  makes CAST's tools visible from turn one, same as Read/Grep/Bash already
  are -- turning "did Claude ever discover the tool exists" from a
  confound into a non-issue, so what's left to measure is the real
  question: given equal visibility, does Claude choose to use it, and what
  does that cost.

  Three conditions, not two:
    without      -- CAST not loaded at all.
    with         -- CAST loaded and visible; Claude decides on its own
                    whether to call it. This is the "revealed preference"
                    condition -- real data showed it call CAST 5/5 times in
                    one batch and only 3/5 in another, on the identical
                    prompt, so "available" does not mean "used".
    with-forced  -- CAST loaded, and the prompt explicitly instructs Claude
                    to use it ($ForceInstruction, appended verbatim to the
                    SAME base $q.prompt -- not a separately-written prompt,
                    so wording never drifts between "with" and
                    "with-forced"). There is no CLI-level equivalent of the
                    API's tool_choice to force this mechanically; a strong
                    prompt instruction is the only lever available through
                    `claude -p`, and it is still not a hard guarantee --
                    check used_mcp_tool on with-forced rows too rather than
                    assume the instruction worked.
  "with" answers "does Claude choose to use CAST, and does that help".
  "with-forced" answers "when CAST is used, how good is the outcome",
  without waiting on whether it happens to reach for it naturally. Keep
  both rather than replacing one with the other -- they're different
  questions and you already have real data showing they can diverge.

Structured output (--json-schema)
  Any question in -QuestionsFile can carry an optional "json_schema" field
  (a real JSON Schema object, not a string). When present, it's passed
  through to `claude -p` via --json-schema, which forces the run to end
  with a call to a synthetic StructuredOutput tool instead of free text --
  confirmed by hand: the stream-json "result" event then carries both the
  usual "result" string AND a "structured_output" object that already
  validates against the schema. That object is logged verbatim below
  (record.structured_output), so a question whose answer is a set (which
  tables, which pages) can be scored by plain set arithmetic against
  bench-questions.json's "expected" field -- no LLM-judge extraction step
  needed for that question. Questions with no "json_schema" behave exactly
  as before: free text in "result", "structured_output" stays null.

  This is not free. Confirmed by hand: forcing structured output adds a
  turn (num_turns goes up by roughly one) and a small extra cost for the
  enforcement round-trip, and it can change *what* Claude does along the
  way -- e.g. suppress prose reasoning that might otherwise have surfaced
  a hallucinated table name in a readable way. Treat "used_json_schema"
  as a cohort split, the same way "condition" already is: don't average a
  schema-on row against a schema-off row for the same question_id and
  call it one distribution. Old rows from before this field existed won't
  have it at all, which is a third cohort, not a missing value -- don't
  silently coerce it to false.

  A JSON Schema is nothing but colons, braces, and double quotes, and
  getting a value like that intact through PowerShell to a native command
  is the actual hard part here -- not the CLI flag itself. On at least one
  real machine, "claude" resolves to claude.ps1 (a standard npm install:
  claude.ps1 / claude.cmd / claude next to each other, not a standalone
  .exe), and that script does its own internal "& node ... $args" hop to
  reach the real engine -- a hop this script has no way to see or control.
  If --json-schema comes back with "not valid JSON" / a truncated schema
  on your machine, that inner hop is almost certainly where it's
  happening, and it's a known Windows PowerShell 5.1 weakness (fixed in
  PowerShell 7.3's argument-passing rewrite) triggered specifically by an
  argument full of embedded quotes -- not something fixable from out here
  by changing how this script calls claude. Two real fixes, in order of
  effort: (1) run this script with `pwsh` instead of `powershell` (7.3+ --
  check with $PSVersionTable.PSVersion -- fixes the SAME internal hop
  since claude.ps1 runs in whatever engine invoked it); (2) `claude
  install` to switch from the npm shim to the native build, which removes
  the extra hop entirely. Below, a version check warns once at runtime if
  a schema-bearing question is about to run under < 7.3 so this isn't a
  silent surprise.

Model selection (-Model)
  Empty by default, which leaves `claude -p` on whatever model your CLI
  config/subscription resolves to (usually the current default Sonnet).
  Set -Model to a Claude Code model alias or full model ID -- e.g. "haiku",
  "sonnet", "opus", or a dated model string -- to run the whole benchmark
  against a specific model instead. Verify the alias resolves on your
  machine first with a throwaway call (`claude --model haiku -p "hi"`)
  before a full run, since accepted values can change with the CLI version.

  Every record logs which model actually ran it (record.model), and
  model_usage (from modelUsage in the stream-json result) still separately
  breaks down cost per model actually billed -- useful confirmation that a
  Haiku run didn't quietly fall back to a bigger model for some sub-step.

  Either point -ResultsFile at a model-specific file (e.g. results-haiku.jsonl)
  or append Haiku rows into the same file as default-model rows -- both are
  fine now. score-results.py reads record.model off each row (falling back to
  "default" if the field is missing entirely, for rows written before -Model
  existed), copies it into every scored row in scores.jsonl, and groups its
  console summary by (app, question_id, model, condition). Mixing models into
  one results.jsonl no longer blends a Haiku run's accuracy into a Sonnet
  run's median -- it just produces separate, model-pure groups. Keeping
  model-specific files is still reasonable if you'd rather not mix them at
  the source, but it's no longer required for correct scoring.

Question filtering (-QuestionIds)
  Empty by default, which runs every question in -QuestionsFile. Set
  -QuestionIds to one or more question "id" values (e.g. "table-count") to
  run only those -- useful for a focused comparison (like a single-model,
  single-question CAST-impact study) without needing a separate, hand-
  trimmed copy of bench-questions.json. Same comma-splitting rule as
  -Conditions applies: `-QuestionIds table-count` and
  `-QuestionIds "table-count,pages-directly-related-to-PrivateMessage-table"`
  both work whether invoked interactively or via `pwsh -File`.

CAST Imaging application name (-CastImagingAppName)
  Empty by default -- nothing is added to the prompt and behavior is
  unchanged from before this parameter existed. Set it to tell Claude which
  application to look for INSIDE CAST Imaging itself when it calls
  mcp__CASTImaging__* tools (a CAST Imaging server/instance can host more
  than one application, so the tools need to know which one to search --
  without this, Claude either has to search/guess, or falls back on
  whatever CAST Imaging treats as a default). This is deliberately a
  DIFFERENT thing from -AppName: -AppName is just this script's own label
  for grouping rows in the results file (e.g. "recipe", "bigger-app") and
  is never sent to Claude at all, whereas -CastImagingAppName is text
  injected into the prompt itself and has to match the application's exact
  name as registered in CAST Imaging. They'll often be similar strings for
  the same run, but conflating them is a mistake -- renaming one has no
  effect on the other.

  Only added when CAST is actually loaded, i.e. only on "with" and
  "with-forced" runs -- appended to $q.prompt right before the
  with-forced-only $ForceInstruction, so it applies to both MCP conditions
  and never touches "without" runs (which have no CAST tools to name an
  application for in the first place). Every record also logs
  record.cast_imaging_app_name ($null when unset) so a scored row is
  self-documenting about which CAST application it targeted, the same way
  record.model documents which model ran it.
#>

param(
  [Parameter(Mandatory=$true)][string]$RepoPath,
  [Parameter(Mandatory=$true)][string]$AppName,
  [string]$QuestionsFile = (Join-Path $PSScriptRoot "bench-questions.json"),
  [string]$McpConfigPath = (Join-Path $RepoPath "cast.json"),
  [string]$ResultsFile   = (Join-Path $PSScriptRoot "results.jsonl"),
  [int]$Runs = 5,
  [string[]]$Conditions = @("without","with"),
  [string[]]$QuestionIds = @(),
  [string]$Model = "",
  [string]$CastImagingAppName = "",
  [string]$BaseAllowedTools = "Read,Grep,Glob,Bash(git *),Bash(ls *),Bash(find *)",
  [string]$ForceInstruction = "You have access to CAST Imaging MCP tools for structural and transaction analysis of this codebase. Use them to answer this question rather than relying solely on reading the source code directly."
)

$ErrorActionPreference = "Stop"

# Accepts either a real array (-Conditions without with-forced -- only binds
# as multiple elements when this script is invoked through PowerShell's own
# parser, e.g. typed directly at a prompt) or a single comma-joined string
# (-Conditions without,with,with-forced). The comma form is what actually
# arrives when this script is run via "pwsh -File run-benchmark.ps1 ...".
# Confirmed by hand: -File hands arguments to the script as raw text,
# bypassing the array-literal parsing that splits a comma-separated value
# into multiple elements at an interactive prompt -- so
# "without,with,with-forced" arrives as ONE array element containing all
# three names glued together, not three elements. [ValidateSet] can't sit
# on the parameter itself for this reason: it would reject that one
# glued-together string before this code ever gets a chance to split it,
# which is exactly the "does not belong to the set" error this replaces.
# Splitting and validating by hand here works the same regardless of which
# way the script was invoked.
$Conditions = $Conditions | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }
$allowedConditions = @("without", "with", "with-forced")
foreach ($c in $Conditions) {
  if ($allowedConditions -notcontains $c) {
    throw "Invalid -Conditions value '$c'. Allowed values: $($allowedConditions -join ', ')"
  }
}

# See the header note above: without this, CAST's tool definitions are
# withheld until Claude proactively searches and finds them, so a "with"
# run could fail to use CAST simply because it never searched -- not
# because it chose not to. This forces every tool (built-in and MCP) to be
# visible in context from turn one, for both conditions.
$env:ENABLE_TOOL_SEARCH = "false"

if (-not (Test-Path $RepoPath))      { throw "RepoPath not found: $RepoPath" }
if (-not (Test-Path $QuestionsFile)) { throw "QuestionsFile not found: $QuestionsFile" }

$questions = Get-Content $QuestionsFile -Raw | ConvertFrom-Json

# Same comma-splitting rationale as -Conditions above: normalize by hand
# rather than rely on [ValidateSet], since a `pwsh -File` invocation hands
# "table-count,pages-directly-related-to-PrivateMessage-table" in as ONE
# glued string, not two array elements. Validated against the actual ids
# found in $QuestionsFile (not a hardcoded list) since the allowed set is
# whatever bench-questions.json happens to define.
$QuestionIds = $QuestionIds | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }
if ($QuestionIds.Count -gt 0) {
  $allQuestionIds = $questions | ForEach-Object { $_.id }
  foreach ($qid in $QuestionIds) {
    if ($allQuestionIds -notcontains $qid) {
      throw "Invalid -QuestionIds value '$qid'. Ids present in ${QuestionsFile}: $($allQuestionIds -join ', ')"
    }
  }
  $questions = $questions | Where-Object { $QuestionIds -contains $_.id }
}

# See the header note "Structured output" above: a schema-bearing question
# is the one case that can hit the PowerShell-version-dependent quoting
# weakness inside claude's own npm shim. Warn once, up front, rather than
# let it surface as a cryptic mid-run "not valid JSON" error with no
# obvious cause.
$anySchemaQuestions = $questions | Where-Object { $_.PSObject.Properties.Match("json_schema").Count -gt 0 -and $_.json_schema }
if ($anySchemaQuestions -and $PSVersionTable.PSVersion -lt [version]"7.3") {
  Write-Host "WARNING: PowerShell $($PSVersionTable.PSVersion) detected, and at least one question uses json_schema." -ForegroundColor Yellow
  Write-Host "         Versions below 7.3 are known to mangle arguments full of embedded quotes -- exactly what a" -ForegroundColor Yellow
  Write-Host "         JSON Schema is -- when claude is installed via npm (claude.ps1 calling node internally)." -ForegroundColor Yellow
  Write-Host "         If a schema question comes back with 'not valid JSON', re-run this script with 'pwsh' (7.3+)" -ForegroundColor Yellow
  Write-Host "         instead of 'powershell', or run ``claude install`` to switch to the native build." -ForegroundColor Yellow
}

Push-Location $RepoPath
try {
  # Disable Claude Code's auto memory for every call this script makes. Auto
  # memory is scoped per git repo (~/.claude/projects/<project>/memory/), not
  # per session, so without this a "with-forced" run's saved answer silently
  # leaks into every later "without"/"with" run in the same repo -- see the
  # CORRECTION note above the param() block for the incident that proved it.
  # Scoped to $env:, so it only affects this script's process tree (and any
  # `claude` child processes it spawns), not your interactive shell.
  $env:CLAUDE_CODE_DISABLE_AUTO_MEMORY = "1"

  foreach ($q in $questions) {
    foreach ($condition in $Conditions) {

      $usesMcp = ($condition -eq "with" -or $condition -eq "with-forced")

      $allowedTools = $BaseAllowedTools
      $mcpArgs = @()
      if ($usesMcp) {
        if (-not (Test-Path $McpConfigPath)) { throw "McpConfigPath not found: $McpConfigPath (needed for the '$condition' condition)" }
        $allowedTools += ",mcp__CASTImaging__*"
        $mcpArgs = @("--mcp-config", $McpConfigPath)
      }

      # Same base prompt for every condition; "with-forced" only appends the
      # forcing instruction on top, so wording never diverges between "with"
      # and "with-forced" by accident.
      $promptText = $q.prompt

      # See header note "CAST Imaging application name" above: only added
      # when CAST is actually loaded, so a "without" run's prompt is
      # untouched. Appended BEFORE $ForceInstruction so a with-forced
      # prompt reads "...question... / which app to search / go use CAST"
      # in a sensible order rather than the instruction and the app name
      # fighting for the last word.
      if ($usesMcp -and $CastImagingAppName) {
        $promptText = "$promptText`n`nWhen using CAST Imaging MCP tools, the application to search is named `"$CastImagingAppName`" -- use that application, not any other one that may also be registered in CAST Imaging."
      }

      if ($condition -eq "with-forced") {
        $promptText = "$promptText`n`n$ForceInstruction"
      }

      # Optional per-question JSON Schema (see header note "Structured
      # output" above). $q.json_schema, if present, is already a nested
      # PSCustomObject courtesy of ConvertFrom-Json above -- flatten it back
      # to a compact JSON string, since that's the shape --json-schema wants
      # on the command line. Questions without this field pass $null
      # straight through and nothing about the run changes.
      $jsonSchemaArg = $null
      if ($q.PSObject.Properties.Match("json_schema").Count -gt 0 -and $q.json_schema) {
        $jsonSchemaArg = ($q.json_schema | ConvertTo-Json -Depth 20 -Compress)
      }

      for ($i = 1; $i -le $Runs; $i++) {
        Write-Host "== $AppName | $($q.id) | $condition | run $i/$Runs ==" -ForegroundColor Cyan

        $claudeArgs = @(
          "-p", $promptText,
          "--output-format", "stream-json",
          "--verbose",
          "--allowedTools", $allowedTools
        ) + $mcpArgs

        if ($jsonSchemaArg) {
          $claudeArgs += @("--json-schema", $jsonSchemaArg)
        }

        # Empty by default (leaves claude on whatever model the CLI/
        # subscription resolves to). See header note "Model selection"
        # above for why -ResultsFile should be model-specific rather than
        # relying on record.model alone to keep cohorts separated later.
        if ($Model) {
          $claudeArgs += @("--model", $Model)
        }

        # Back to the original, simple invocation. The custom-quoting /
        # ProcessStartInfo detour tried here previously rested on an
        # assumption that turned out wrong: it assumed "claude" is a
        # standalone .exe, but on a real test machine it resolves to
        # claude.ps1 (CommandType ExternalScript -- a standard npm global
        # install: claude.ps1 / claude.cmd / claude side by side, not a
        # single binary). Process.Start can't launch a .ps1 directly
        # ("specified executable is not a valid application for this OS
        # platform" -- confirmed by hand), so that approach cannot work
        # regardless of how carefully the arguments were escaped.
        #
        # More importantly, that also means the ORIGINAL corruption was
        # never happening at this boundary in the first place: "&
        # claude @claudeArgs" invokes claude.ps1 as an in-process
        # PowerShell script call (values bound directly as .NET objects,
        # no OS command-line string involved), which is not where Windows'
        # embedded-quote quirks apply. The actual native-command hop is
        # ONE LEVEL INSIDE claude.ps1 itself (its own "& node ... $args"
        # call to reach the real engine) -- code this script doesn't own
        # and can't intercept. See the header note "Structured output" for
        # what to do if a schema-bearing question hits that.
        #
        # Splatting (@claudeArgs) hands each element to claude as its own
        # argument, so the prompt's spaces/punctuation don't need manual
        # quoting the way they would in cmd.exe.
        # stream-json prints one JSON object per line (NDJSON): every
        # message and tool call as it happens, then a final "result" line
        # with the same cost/usage fields the old plain "json" format gave.
        # PowerShell already splits external-command stdout into one array
        # element per line, so $rawLines is ready to walk line-by-line.
        $rawLines = & claude @claudeArgs

        $record = [ordered]@{
          timestamp        = (Get-Date).ToString("o")
          app              = $AppName
          question_id      = $q.id
          condition        = $condition
          run_index        = $i
          model            = if ($Model) { $Model } else { "default" }
          cast_imaging_app_name = if ($usesMcp -and $CastImagingAppName) { $CastImagingAppName } else { $null }
          used_json_schema = [bool]$jsonSchemaArg
          correct          = $null   # fill in true/false by hand after reading 'result'
        }

        $toolsUsed = New-Object System.Collections.Generic.List[string]
        $finalResult = $null

        foreach ($line in $rawLines) {
          if ([string]::IsNullOrWhiteSpace($line)) { continue }
          try {
            $evt = $line | ConvertFrom-Json
          } catch {
            continue  # tolerate any stray non-JSON line rather than aborting the run
          }

          if ($evt.type -eq "assistant" -and $evt.message -and $evt.message.content) {
            foreach ($block in $evt.message.content) {
              if ($block.type -eq "tool_use" -and $block.name -and (-not $toolsUsed.Contains($block.name))) {
                $toolsUsed.Add($block.name)
              }
            }
          } elseif ($evt.type -eq "result") {
            $finalResult = $evt
          }
        }

        $usedMcpTool = $false
        foreach ($t in $toolsUsed) {
          if ($t -like "mcp__CASTImaging__*") { $usedMcpTool = $true }
        }
        $record.tools_used    = ($toolsUsed -join ";")
        $record.used_mcp_tool = $usedMcpTool

        if ($finalResult) {
          $record.cost_usd              = $finalResult.total_cost_usd
          $record.num_turns             = $finalResult.num_turns
          $record.input_tokens          = $finalResult.usage.input_tokens
          $record.output_tokens         = $finalResult.usage.output_tokens
          $record.cache_creation_tokens = $finalResult.usage.cache_creation_input_tokens
          $record.cache_read_tokens     = $finalResult.usage.cache_read_input_tokens
          $record.session_id            = $finalResult.session_id
          $record.result                = $finalResult.result
          # Present only on json_schema runs; validated against the
          # question's schema already, so scoring can diff it against
          # bench-questions.json's "expected" with plain set arithmetic
          # instead of an LLM extraction pass. $null on every other run.
          $record.structured_output     = $finalResult.structured_output
          # modelUsage breaks total_cost_usd down per model. Worth keeping
          # because a run can quietly bill a second, smaller model
          # alongside the main one (observed: a few cents on a Haiku call
          # neither condition asked for) -- without this field that cost is
          # invisible inside the blended total_cost_usd number.
          $record.model_usage           = $finalResult.modelUsage
          $record.error                 = $null
        } else {
          $record.error      = "No 'result' event found in stream-json output"
          $record.raw_output = ($rawLines -join "`n")
        }

        # File.AppendAllText instead of Add-Content: a bare cmdlet call here
        # was observed to intermittently throw "Stream was not readable" on
        # the very first write to a fresh results file (this box's Desktop
        # is under a synced folder -- OneDrive/AV can hold a transient lock
        # on file creation). AppendAllText is a lower-level, more reliable
        # primitive for exactly this, and a few retries absorb a lock that
        # clears within milliseconds rather than losing the run's data.
        # UTF8 (no BOM) here matches what analyze-results.py already
        # expects: it opens with "utf-8-sig", which reads a BOM if present
        # and is a plain no-op if there isn't one, so this is safe either way.
        # Renamed to $outLine (not $line) -- the parsing loop above already
        # used $line as its foreach variable; PowerShell loop variables leak
        # into the enclosing scope, so reusing the name here would still
        # work today but would silently break if anything moved.
        $outLine = ($record | ConvertTo-Json -Compress -Depth 6)
        $attempt = 0
        while ($true) {
          try {
            [System.IO.File]::AppendAllText($ResultsFile, $outLine + "`n", [System.Text.Encoding]::UTF8)
            break
          } catch {
            $attempt++
            if ($attempt -ge 5) { throw }
            Start-Sleep -Milliseconds 200
          }
        }
      }
    }
  }
}
finally {
  Pop-Location
}

Write-Host "`nDone. Results appended to $ResultsFile" -ForegroundColor Green
Write-Host "Next: python analyze-results.py `"$ResultsFile`"" -ForegroundColor Green