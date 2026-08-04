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
  one run's answer leak into the next).

  Note on --bare: it also skips auto-loading hooks, skills, plugins,
  auto-memory, and CLAUDE.md, which would be a nice extra guarantee -- but
  it ALSO skips OAuth/keychain reads, so it only works if ANTHROPIC_API_KEY
  is set. If you're logged into `claude` normally (OAuth, e.g. a Claude
  subscription), --bare will fail with "Not logged in". This script does
  NOT use --bare for that reason; the no-continue/no-resume rule above is
  what actually guarantees no memory carries over, and it doesn't need
  --bare to hold. If you do have an API key and want the extra isolation,
  set $env:ANTHROPIC_API_KEY and add "--bare" back into $claudeArgs below.

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
#>

param(
  [Parameter(Mandatory=$true)][string]$RepoPath,
  [Parameter(Mandatory=$true)][string]$AppName,
  [string]$QuestionsFile = (Join-Path $PSScriptRoot "bench-questions.json"),
  [string]$McpConfigPath = (Join-Path $RepoPath "cast.json"),
  [string]$ResultsFile   = (Join-Path $PSScriptRoot "results.jsonl"),
  [int]$Runs = 5,
  [ValidateSet("without","with","with-forced")]
  [string[]]$Conditions = @("without","with"),
  [string]$BaseAllowedTools = "Read,Grep,Glob,Bash(git *),Bash(ls *),Bash(find *)",
  [string]$ForceInstruction = "You have access to CAST Imaging MCP tools for structural and transaction analysis of this codebase. Use them to answer this question rather than relying solely on reading the source code directly."
)

$ErrorActionPreference = "Stop"

# See the header note above: without this, CAST's tool definitions are
# withheld until Claude proactively searches and finds them, so a "with"
# run could fail to use CAST simply because it never searched -- not
# because it chose not to. This forces every tool (built-in and MCP) to be
# visible in context from turn one, for both conditions.
$env:ENABLE_TOOL_SEARCH = "false"

if (-not (Test-Path $RepoPath))      { throw "RepoPath not found: $RepoPath" }
if (-not (Test-Path $QuestionsFile)) { throw "QuestionsFile not found: $QuestionsFile" }

$questions = Get-Content $QuestionsFile -Raw | ConvertFrom-Json

Push-Location $RepoPath
try {
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
      if ($condition -eq "with-forced") {
        $promptText = "$($q.prompt)`n`n$ForceInstruction"
      }

      for ($i = 1; $i -le $Runs; $i++) {
        Write-Host "== $AppName | $($q.id) | $condition | run $i/$Runs ==" -ForegroundColor Cyan

        $claudeArgs = @(
          "-p", $promptText,
          "--output-format", "stream-json",
          "--verbose",
          "--allowedTools", $allowedTools
        ) + $mcpArgs

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
          timestamp   = (Get-Date).ToString("o")
          app         = $AppName
          question_id = $q.id
          condition   = $condition
          run_index   = $i
          correct     = $null   # fill in true/false by hand after reading 'result'
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
          $record.error                 = $null
        } else {
          $record.error      = "No 'result' event found in stream-json output"
          $record.raw_output = ($rawLines -join "`n")
        }

        ($record | ConvertTo-Json -Compress -Depth 6) | Add-Content -Path $ResultsFile -Encoding utf8
      }
    }
  }
}
finally {
  Pop-Location
}

Write-Host "`nDone. Results appended to $ResultsFile" -ForegroundColor Green
Write-Host "Next: python analyze-results.py `"$ResultsFile`"" -ForegroundColor Green