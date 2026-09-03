# run-benchmark-loop.ps1
# ---------------------------------------------------------------------------
# Continuous overnight/evening runner. Unlike run-benchmark-nightly.ps1
# (fires once, one fixed batch, exits), this script loops internally,
# doing ONE run at a time (-Runs 1), and inspects the JSONL row that run
# just wrote IMMEDIATELY after it's written -- not after a whole batch --
# so a limit hit is caught on the very first affected line, even if it's
# the very first call of the whole run (zero tokens/cost from the start
# included -- detection is purely on the "result" text, never on
# token/cost deltas, so there's nothing to "warm up" first).
#
# Confirmed real failure message (from an actual results.jsonl row, seen
# 2026-09-02):
#   "You've hit your monthly spend limit \u00b7 raise it at claude.ai/settings/usage"
# When this is seen, the fix is NOT to wait some generic backoff -- it's to
# read THAT ROW'S OWN "timestamp" field, add 5 hours, and resume at that
# exact computed time (Ayoub's instruction, based on how this limit
# actually resets on his plan).
#
# "Not logged in" is handled differently: waiting can't fix an expired/
# missing login, so that stops the loop with a clear message instead of
# retrying blindly forever.
#
# Routes through run-benchmark-pro.ps1 if present (separate-account setup,
# see that file / its .example template), else falls back to
# run-benchmark.ps1 directly -- same portable fallback as
# run-benchmark-nightly.ps1.
# ---------------------------------------------------------------------------

param(
    [datetime]$StopTime = (Get-Date -Hour 7 -Minute 0 -Second 0),
    [int]$PauseSecondsBetweenRuns = 10,
    [int]$MaxSpendLimitCycles = 6,
    [int]$MinSameConfigGapMinutes = 6
)

# If StopTime already passed today (e.g. launched at 18:00 for a 07:00
# cutoff), it means tomorrow morning.
if ($StopTime -lt (Get-Date)) { $StopTime = $StopTime.AddDays(1) }

# EDIT THIS -- the only per-person path in this file. Point it at your own
# local checkout of the Hades source (the nested "hades-main\hades-main\COBOL"
# folder, not the outer clone root). Everything else below resolves relative
# to wherever this script itself lives, so it doesn't need editing per-person.
$HadesSourcePath = "C:\Cast\Code-for-demos\hades-main\hades-main\COBOL"

# Portable: resolves to wherever THIS script physically lives, so it works
# for anyone who clones the repo -- no per-person editing needed for this one.
$repoPathScript = $PSScriptRoot
$resultsFile    = Join-Path $repoPathScript "results.jsonl"
$logDir         = Join-Path $repoPathScript "nightly-logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$stamp   = Get-Date -Format "yyyy-MM-dd_HHmmss"
$logFile = Join-Path $logDir "loop_$stamp.log"

function Write-Log($msg) {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg" | Tee-Object -FilePath $logFile -Append
}

# Strips the last line of results.jsonl -- used when that line is a failed
# attempt (spend limit / not logged in) that must not persist as real data.
function Remove-LastResultRow {
    if (-not (Test-Path $resultsFile)) { return }
    $allLinesNow = Get-Content $resultsFile
    if ($allLinesNow.Count -le 1) {
        Clear-Content $resultsFile
        Write-Log "Stripped the failed row from results.jsonl (file now empty)."
    } else {
        $allLinesNow[0..($allLinesNow.Count - 2)] | Set-Content $resultsFile
        Write-Log "Stripped the failed row from results.jsonl ($($allLinesNow.Count - 1) row(s) remain)."
    }
}

Set-Location $repoPathScript

$proWrapper   = Join-Path $repoPathScript "run-benchmark-pro.ps1"
$targetScript = if (Test-Path $proWrapper) { $proWrapper } else { Join-Path $repoPathScript "run-benchmark.ps1" }
Write-Log "=== Loop starting. Target: $targetScript. Stop time: $StopTime ==="

$conditions = @("without", "with", "with-forced")
$condIndex = 0
$spendLimitCycles = 0

# Anti-cache-contamination: "with" and "with-forced" share the EXACT same
# tool config (BaseAllowedTools + mcp__CASTImaging__*, same -McpConfigPath),
# so back-to-back calls between them (or repeats of either) are eligible
# for Anthropic's prompt cache to silently reuse the system-prompt/tool-
# definition prefix across what are supposed to be fully independent runs
# -- confirmed real behavior (5-minute default TTL, keyed by content hash,
# not by session/--continue). "without" has its own, different tool config,
# so it never shares a cache key with "with"/"with-forced". Concretely
# observed in real results.jsonl data: a "with-forced" run 78s after a
# "with" run had cache_creation_tokens crash from a normal ~100k-250k down
# to 6720 -- a near-total cache hit, and a cost far below its usual range.
# Fix: track the last call-start time PER tool-config class, and force at
# least $MinSameConfigGapMinutes between two calls of the same class so the
# cache has provably expired before the next one starts.
$lastCallStart = @{ "without" = $null; "mcp" = $null }

while ((Get-Date) -lt $StopTime) {
    $condition = $conditions[$condIndex % $conditions.Count]
    $configClass = if ($condition -eq "without") { "without" } else { "mcp" }

    if ($lastCallStart[$configClass]) {
        $sinceLast = (Get-Date) - $lastCallStart[$configClass]
        $minGap    = New-TimeSpan -Minutes $MinSameConfigGapMinutes
        if ($sinceLast -lt $minGap) {
            $extraWait = $minGap - $sinceLast
            Write-Log "Anti-cache-contamination cooldown: last '$configClass'-class call started $([math]::Round($sinceLast.TotalSeconds))s ago, need >=$($MinSameConfigGapMinutes)min gap before this '$condition' run -- waiting $([math]::Round($extraWait.TotalSeconds))s more."
            Start-Sleep -Seconds ([int][math]::Ceiling($extraWait.TotalSeconds))
        }
    }
    $lastCallStart[$configClass] = Get-Date

    $benchParams = @{
        RepoPath      = $HadesSourcePath
        AppName       = "hades"
        QuestionsFile = (Join-Path $repoPathScript "bench-questions-hades.json")
        McpConfigPath = (Join-Path $repoPathScript "cast.json")
        Conditions    = @($condition)
        QuestionIds   = @("calls-to-immdates")
        Runs          = 1
    }

    Write-Log "Running: calls-to-immdates / $condition (run 1/1 this call)"
    try {
        & $targetScript @benchParams *>> $logFile
    } catch {
        Write-Log "Invocation threw an exception (structural, not a per-run result): $($_.Exception.Message)"
    }

    # Inspect the row that call JUST wrote -- the last line of the file.
    $lastLine = if (Test-Path $resultsFile) { Get-Content $resultsFile -Tail 1 } else { $null }
    if (-not $lastLine) {
        Write-Log "No line appeared in results.jsonl after that call -- something structural broke before any row was written. Waiting $PauseSecondsBetweenRuns s and retrying."
        Start-Sleep -Seconds $PauseSecondsBetweenRuns
        continue
    }

    $row = $null
    try { $row = $lastLine | ConvertFrom-Json } catch { $row = $null }

    if (-not $row) {
        Write-Log "Last line wasn't valid JSON -- skipping interpretation, pausing $PauseSecondsBetweenRuns s."
        Start-Sleep -Seconds $PauseSecondsBetweenRuns
        continue
    }

    $resultText = [string]$row.result

    if ($resultText -match "spend limit|session limit") {
        $spendLimitCycles++
        Write-Log "Usage-limit line detected (row timestamp: $($row.timestamp)). Cycle $spendLimitCycles/$MaxSpendLimitCycles. Raw: $resultText"
        Remove-LastResultRow

        if ($spendLimitCycles -ge $MaxSpendLimitCycles) {
            Write-Log "Hit $MaxSpendLimitCycles usage-limit cycles -- stopping for tonight instead of continuing to wait/retry."
            break
        }

        # Prefer the EXACT reset time embedded in the message itself over a
        # guess. Real observed shapes:
        #   "...your session limit resets 2pm (America/New_York)"
        #   "You've hit your session limit ... resets 3:10am (America/New_York)"
        # Anthropic tells us exactly when it resets, so parse that instead of
        # assuming +5h. Falls back to row timestamp + 5h only if this clause
        # isn't present (e.g. a bare monthly-spend-limit message with no
        # reset clause at all).
        $resumeAt = $null
        if ($resultText -match "resets\s+(\d{1,2})(?::(\d{2}))?\s*([ap]m)\s*\(([^)]+)\)") {
            $rHour = [int]$matches[1]
            $rMin  = if ($matches[2]) { [int]$matches[2] } else { 0 }
            $rAmPm = $matches[3].ToLower()
            $rTz   = $matches[4]
            if ($rAmPm -eq "pm" -and $rHour -ne 12) { $rHour += 12 }
            if ($rAmPm -eq "am" -and $rHour -eq 12) { $rHour = 0 }
            try {
                $tzInfo     = [System.TimeZoneInfo]::FindSystemTimeZoneById($rTz)
                $utcNow     = [DateTime]::UtcNow
                $nowInTz    = [System.TimeZoneInfo]::ConvertTimeFromUtc($utcNow, $tzInfo)
                $resetLocal = New-Object DateTime($nowInTz.Year, $nowInTz.Month, $nowInTz.Day, $rHour, $rMin, 0)
                if ($resetLocal -le $nowInTz) { $resetLocal = $resetLocal.AddDays(1) }
                $resetUtc = [System.TimeZoneInfo]::ConvertTimeToUtc($resetLocal, $tzInfo)
                $resumeAt = [datetimeoffset]$resetUtc
                Write-Log ("Parsed exact reset time from the message: {0:D2}:{1:D2} ({2}) -> resume at {3} (UTC)." -f $rHour, $rMin, $rTz, $resumeAt)
            } catch {
                Write-Log "Found a 'resets HH:MM(am/pm) (Timezone)' clause but could not resolve timezone '$rTz' ($($_.Exception.Message)) -- falling back to timestamp+5h."
            }
        }

        if (-not $resumeAt) {
            try {
                $rowTime  = [datetimeoffset]::Parse($row.timestamp)
                $resumeAt = $rowTime.AddHours(5)
            } catch {
                Write-Log "Could not parse this row's timestamp ('$($row.timestamp)') -- falling back to a flat 5h wait from now."
                $resumeAt = [datetimeoffset]::Now.AddHours(5)
            }
        }

        $waitSpan = $resumeAt - [datetimeoffset]::Now

        if ($waitSpan.TotalSeconds -le 0) {
            Write-Log "Computed resume time is already in the past (resume at = $resumeAt) -- retrying almost immediately (short 60s pause) instead of sleeping negative time."
            Start-Sleep -Seconds 60
        } else {
            $remaining = $StopTime - (Get-Date)
            if ($waitSpan -gt $remaining) {
                Write-Log "Resume time ($resumeAt) is past the stop time ($StopTime) -- stopping instead of sleeping through the cutoff."
                break
            }
            Write-Log "Sleeping until $resumeAt (~$([math]::Round($waitSpan.TotalMinutes)) min) before retrying $condition."
            Start-Sleep -Seconds ([int][math]::Max(1, $waitSpan.TotalSeconds))
        }
        # Don't advance condition/index -- retry the SAME condition next loop.
        continue
    }

    if ($resultText -match "Not logged in") {
        Write-Log "'Not logged in' detected -- this needs a manual /login, waiting can't fix it. Stopping the loop rather than retrying blindly."
        Remove-LastResultRow
        break
    }

    # Genuine result (success or some other, non-limit error) -- log outcome,
    # reset the spend-limit cycle counter, move to the next condition.
    $spendLimitCycles = 0
    $costNote = if ($null -ne $row.cost_usd) { "cost_usd=$($row.cost_usd)" } else { "" }
    Write-Log "Row OK for $condition ($costNote). Moving to next condition."
    $condIndex++
    Start-Sleep -Seconds $PauseSecondsBetweenRuns
}

Write-Log "=== Loop stopped at $(Get-Date) (StopTime was $StopTime) ==="

if (Test-Path $resultsFile) {
    $tailCount = (Get-Content $resultsFile | Measure-Object -Line).Lines
    "=== Session end: $tailCount total row(s) now in results.jsonl ===" | Tee-Object -FilePath $logFile -Append
}
