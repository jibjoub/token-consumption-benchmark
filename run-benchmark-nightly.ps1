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
#
# Account routing (optional, per-person): if a run-benchmark-pro.ps1 exists
# next to this file, it's used instead of calling run-benchmark.ps1 directly
# -- that's a local, gitignored, per-person file that routes the CLI through
# a separate Claude account (e.g. a company Team/Enterprise seat) instead of
# whichever account the default `claude` CLI is logged into, so this
# project's usage doesn't eat into a personal account's quota. See
# run-benchmark-pro.ps1.example for the template and README.md's "Routing
# through a separate Claude account" section for the one-time setup. If no
# run-benchmark-pro.ps1 exists (e.g. a fresh clone that hasn't set one up
# yet), this falls back to run-benchmark.ps1 directly with a warning --
# nothing breaks, it just uses the default account.
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

$benchParams = @{
    RepoPath      = "C:\Cast\Code-for-demos\hades-main\hades-main\COBOL"
    AppName       = "hades"
    QuestionsFile = (Join-Path $repoPathScript "bench-questions-hades.json")
    McpConfigPath = (Join-Path $repoPathScript "cast.json")
    Conditions    = @("without", "with", "with-forced")
    QuestionIds   = @("calls-to-immdates")
    Runs          = 2
}

$proWrapper = Join-Path $repoPathScript "run-benchmark-pro.ps1"
if (Test-Path $proWrapper) {
    "(routing through run-benchmark-pro.ps1 -- separate account)" | Tee-Object -FilePath $logFile -Append
    & $proWrapper @benchParams *>> $logFile
} else {
    "(run-benchmark-pro.ps1 not found -- calling run-benchmark.ps1 directly, using the default account)" | Tee-Object -FilePath $logFile -Append
    & (Join-Path $repoPathScript "run-benchmark.ps1") @benchParams *>> $logFile
}

"=== Nightly run finished $(Get-Date) ===" | Tee-Object -FilePath $logFile -Append

# Quick morning summary: how many new rows landed tonight, how many are
# dead-on-arrival due to login expiry or the account spend limit -- so
# the morning check is a single glance instead of a manual results.jsonl grep.
if (Test-Path $resultsFile) {
    $allLines = Get-Content $resultsFile
    $newLines = $allLines | Select-Object -Skip $linesBefore
    $total  = $newLines.Count
    $failed = ($newLines | Select-String -Pattern "spend limit|Not logged in").Count
    "=== SUMMARY: $total new run(s) logged tonight, $failed failed (login/spend-limit) ===" | Tee-Object -FilePath $logFile -Append
}
