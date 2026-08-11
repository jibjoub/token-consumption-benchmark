#!/usr/bin/env python3
"""
Score results.jsonl against the "expected" ground truth in bench-questions.json,
for any question that has both an "expected" field and structured_output rows.

This is deliberately a SEPARATE, recomputable derived file (scores.jsonl) rather
than something that rewrites results.jsonl or bench-questions.json in place:
results.jsonl stays an append-only observation log, bench-questions.json stays
the single source of truth for ground truth, and this script just joins the two
and computes numbers. Re-run it any time either file changes; nothing here is
hand-edited, so there's nothing to lose by deleting scores.jsonl and rebuilding it.

Why this doesn't need an LLM-judge / Ollama extraction step (for schema-bearing
questions specifically): --json-schema (see run-benchmark.ps1) already forces the
answer into a validated object, logged verbatim as record.structured_output.
Extraction, the actual reason an LLM judge would normally be needed, already
happened at generation time. All that's left is set arithmetic:

    accuracy (recall)    = |expected & found| / |expected|   -- did it find everything?
    noise / excess       = |found - expected| / |found|       -- did it add things that
                                                                  aren't there?
    exact_match          = found == expected exactly

These are two independently meaningful numbers, not one blended "correctness" --
a run can have zero noise (invented nothing) and still low accuracy (found only
part of the true answer), or the reverse (found everything, plus extras). See
the "table-count" scoring below for a real example of the first case: CAST was
used correctly and invented nothing, it just answered a narrower question
(one page's tables) than the one asked (the whole app's tables).

Questions with no "expected" field, or rows with no structured_output (free-text
questions, or json_schema runs that errored before producing one), are skipped
here -- they still need grade-results.py's manual y/n grading.

Usage:
    python score-results.py results.jsonl [bench-questions.json] [--out scores.jsonl]
"""

import sys
import json
import argparse
import statistics
from collections import defaultdict

# Preference order for which array-valued field to compare, when a question's
# "expected" has more than one array field (e.g. table-count also has an
# integer "count" -- not compared as a set, handled separately below).
FIELD_PRIORITY = ["tables", "pages", "files", "items"]


def load_jsonl(path):
    rows = []
    with open(path, "r", encoding="utf-8-sig") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            rows.append(json.loads(line))
    return rows


def pick_compare_field(expected, found):
    """Find the array-valued key present in both dicts. Prefers known names
    (tables/pages/...) so behavior is stable and predictable; falls back to
    the first array field found in common, so a future question's schema
    ("entry_points", whatever) isn't silently unscored just because its
    field name wasn't anticipated here."""
    for key in FIELD_PRIORITY:
        if isinstance(expected.get(key), list) and isinstance(found.get(key), list):
            return key
    for key in expected:
        if isinstance(expected.get(key), list) and isinstance(found.get(key), list):
            return key
    return None


def score_row(row, question):
    expected = question.get("expected")
    found = row.get("structured_output")
    if not expected or not found:
        return None

    field = pick_compare_field(expected, found)

    out = {
        "timestamp": row.get("timestamp"),
        "session_id": row.get("session_id"),
        "app": row.get("app"),
        "question_id": row.get("question_id"),
        "condition": row.get("condition"),
        "run_index": row.get("run_index"),
        "used_mcp_tool": row.get("used_mcp_tool"),
        "used_json_schema": row.get("used_json_schema"),
        "cost_usd": row.get("cost_usd"),
        "compare_field": field,
    }

    if field:
        # Exact string match, case-sensitive, on purpose: these are real SQL
        # identifiers/file names, not prose, so "Recipes" vs "recipes" is a
        # meaningful discrepancy worth surfacing, not noise to normalize away.
        expected_set = {str(x).strip() for x in expected[field]}
        found_set = {str(x).strip() for x in found[field]}
        matched = expected_set & found_set
        missing = expected_set - found_set
        extra = found_set - expected_set

        out["expected_count"] = len(expected_set)
        out["found_count"] = len(found_set)
        out["matched_count"] = len(matched)
        out["missing"] = sorted(missing)
        out["extra"] = sorted(extra)
        out["accuracy"] = (len(matched) / len(expected_set)) if expected_set else None
        out["noise_rate"] = (len(extra) / len(found_set)) if found_set else 0.0
        out["exact_match"] = (not missing) and (not extra)
    else:
        out["accuracy"] = None
        out["noise_rate"] = None
        out["exact_match"] = None

    if "count" in expected and "count" in found:
        out["count_expected"] = expected["count"]
        out["count_found"] = found["count"]
        out["count_correct"] = expected["count"] == found["count"]

    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("results_file")
    ap.add_argument("questions_file", nargs="?", default="bench-questions.json")
    ap.add_argument("--out", default="scores.jsonl")
    args = ap.parse_args()

    questions = {q["id"]: q for q in json.loads(
        open(args.questions_file, "r", encoding="utf-8-sig").read()
    )}
    results = load_jsonl(args.results_file)

    scored = []
    skipped_no_expected = 0
    skipped_no_structured_output = 0
    for row in results:
        if row.get("error"):
            continue
        q = questions.get(row.get("question_id"))
        if not q or "expected" not in q:
            skipped_no_expected += 1
            continue
        if not row.get("structured_output"):
            skipped_no_structured_output += 1
            continue
        s = score_row(row, q)
        if s:
            scored.append(s)

    with open(args.out, "w", encoding="utf-8") as f:
        for s in scored:
            f.write(json.dumps(s) + "\n")

    print(f"Scored {len(scored)} row(s) -> {args.out}")
    if skipped_no_expected:
        print(f"  ({skipped_no_expected} row(s) skipped: question has no 'expected' field -- use grade-results.py)")
    if skipped_no_structured_output:
        print(f"  ({skipped_no_structured_output} row(s) skipped: no structured_output -- free-text run, or a json_schema run that errored)")

    if not scored:
        return

    groups = defaultdict(list)
    for s in scored:
        groups[(s["app"], s["question_id"], s["condition"])].append(s)

    header = (
        f"{'app':<14}{'question':<28}{'condition':<12}{'n':<4}"
        f"{'exact':<8}{'median acc':<12}{'median noise':<13}{'mcp used':<10}"
    )
    print()
    print(header)
    print("-" * len(header))
    for (app, qid, cond), rows in sorted(groups.items()):
        exact = sum(1 for r in rows if r["exact_match"])
        accs = [r["accuracy"] for r in rows if r["accuracy"] is not None]
        noises = [r["noise_rate"] for r in rows if r["noise_rate"] is not None]
        mcp = [r for r in rows if r.get("used_mcp_tool") is not None]
        mcp_str = f"{sum(1 for r in mcp if r['used_mcp_tool'])}/{len(mcp)}" if mcp else "n/a"
        med_acc = f"{statistics.median(accs):.0%}" if accs else "n/a"
        med_noise = f"{statistics.median(noises):.0%}" if noises else "n/a"
        print(f"{app:<14}{qid:<28}{cond:<12}{len(rows):<4}{exact}/{len(rows):<7}{med_acc:<12}{med_noise:<13}{mcp_str:<10}")


if __name__ == "__main__":
    main()