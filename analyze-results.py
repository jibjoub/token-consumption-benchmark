#!/usr/bin/env python3
"""
Summarize results.jsonl produced by run-benchmark.ps1.

Usage:
    python analyze-results.py results.jsonl

For each (app, question, condition) group this prints the number of runs,
median cost in USD, median total tokens (input + output + cache create +
cache read), and -- once you've hand-filled the "correct" field (true/false)
in results.jsonl after reading each run's result against the ground truth --
an accuracy fraction.

Pure standard library, no pip install needed.
"""

import sys
import json
import statistics
from collections import defaultdict


def load_records(path):
    records = []
    # utf-8-sig strips a leading BOM if present (PowerShell's -Encoding utf8
    # writes one) and behaves exactly like plain utf-8 otherwise.
    with open(path, "r", encoding="utf-8-sig") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            records.append(json.loads(line))
    return records


def total_tokens(r):
    return (
        (r.get("input_tokens") or 0)
        + (r.get("output_tokens") or 0)
        + (r.get("cache_creation_tokens") or 0)
        + (r.get("cache_read_tokens") or 0)
    )


def main():
    if len(sys.argv) != 2:
        print("Usage: python analyze-results.py results.jsonl")
        sys.exit(1)

    records = load_records(sys.argv[1])
    if not records:
        print("No records found.")
        return

    groups = defaultdict(list)
    for r in records:
        key = (r.get("app"), r.get("question_id"), r.get("condition"))
        groups[key].append(r)

    header = (
        f"{'app':<14}{'question':<16}{'condition':<10}{'n':<4}"
        f"{'median $':<11}{'median tok':<12}{'accuracy':<10}{'mcp used':<10}"
    )
    print(header)
    print("-" * len(header))

    for (app, qid, cond), rows in sorted(groups.items(), key=lambda kv: (kv[0][0] or "", kv[0][1] or "", kv[0][2] or "")):
        ok_rows = [r for r in rows if not r.get("error")]
        costs = [r["cost_usd"] for r in ok_rows if r.get("cost_usd") is not None]
        toks = [total_tokens(r) for r in ok_rows]
        errors = [r for r in rows if r.get("error")]
        graded = [r for r in rows if r.get("correct") is not None]

        accuracy = (
            f"{sum(1 for r in graded if r['correct'])}/{len(graded)}"
            if graded
            else "ungraded"
        )
        med_cost = f"${statistics.median(costs):.4f}" if costs else "n/a"
        med_tok = f"{int(statistics.median(toks)):,}" if toks else "n/a"

        # Only meaningful for "with" runs -- the server isn't even loaded
        # under "without", so this should read 0/n there by construction.
        # "n/a" (rather than 0/n) marks older rows from before this field
        # existed, so they don't get silently misread as "never used it".
        mcp_rows = [r for r in ok_rows if "used_mcp_tool" in r]
        mcp_used = (
            f"{sum(1 for r in mcp_rows if r.get('used_mcp_tool'))}/{len(mcp_rows)}"
            if mcp_rows
            else "n/a"
        )

        print(
            f"{app:<14}{qid:<16}{cond:<10}{len(rows):<4}"
            f"{med_cost:<11}{med_tok:<12}{accuracy:<10}{mcp_used:<10}"
        )
        if errors:
            print(f"   ! {len(errors)} run(s) failed to parse -- see 'error' field in {sys.argv[1]}")
        if cond == "with" and mcp_rows and all(not r.get("used_mcp_tool") for r in mcp_rows):
            print("   ! CAST was available but never actually called in any of these runs")


if __name__ == "__main__":
    main()