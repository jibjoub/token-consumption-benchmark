# run-benchmark-nightly.ps1
# ---------------------------------------------------------------------------
# Nightly wrapper around run-benchmark.ps1 for the Hades extension of the
# CAST Imaging MCP benchmark. Registered as a Windows Scheduled Task
# ("CastBenchmarkHadesNightly") so the still-missing question/condition
# combos run unattended overnight instead of needing to be launched by hand.
#
# 2026-09-02: narrowed to calls-to-immdates only, per Ayoub's explicit
# request for tonight's run (all 3 conditions still included). -Runs is
# capped at 2 per condition to respect the weekly account-mode spend limit.
# Edit the -QuestionIds / -Conditions / -Runs values below directly if
# priorities change again (e.g. to go back to the other pending Hades
# questions: programs-directly-related-to-EMP-table,
# impact-radius-immeieio -- or to retry impact-ims-pcb-immmbrdb's
# with/with-forced conditions).
# ---------------------------------------------------------------------------

$ErrorActionPreference = "Continue"

$repoPathScript = "C:\Users\ala\Claude\Projects\Orbit Planner\token-consumption-benchmark"
$resultsFile    = Join-Path $repoPathScript "results.jsonl"
$logDir         = Join-Path $repoPathScript "nightly-logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$stamp   = Get-Date -Format "yyyy-MM-dd_HHmmss"
$logFile = Join-Path $logDir "run_$stamp.log"

Set-Location $repoPathScript

# Count existing lines before this run, to isolate what gets added tonight
$linesBefore = 0
if (Test-Path $resultsFile) {
    $linesBefore = (Get-Content $resultsFile | Measure-Object -Line).Lines
}

"=== Nightly run started $(Get-Date) ===" | Tee-Object -FilePath $logFile -Append

& .\run-benchmark.ps1 `
    -RepoPath "C:\Cast\Code-for-demos\hades-main\hades-main\COBOL" `
    -AppName "hades" `
    -QuestionsFile (Join-Path $repoPathScript "bench-questions-hades.json") `
    -McpConfigPath (Join-Path $repoPathScript "cast.json") `
    -Conditions without,with,with-forced `
    -QuestionIds "calls-to-immdates" `
    -Runs 2 *>> $logFile

"=== Nightly run finished $(Get-Date) ===" | Tee-Object -FilePath $logFile -Append

# Quick morning summary: how many new rows landed tonight, how many are
# dead-on-arrival due to login expiry or the account spend limit -- so
# Ayoub can tell at a glance whether the night was productive without
# having to grep results.jsonl himself.
if (Test-Path $resultsFile) {
    $allLines = Get-Content $resultsFile
    $newLines = $allLines | Select-Object -Skip $linesBefore
    $total  = $newLines.Count
    $failed = ($newLines | Select-String -Pattern "spend limit|Not logged in").Count
    "=== SUMMARY: $total new run(s) logged tonight, $failed failed (login/spend-limit) ===" | Tee-Object -FilePath $logFile -Append
}
