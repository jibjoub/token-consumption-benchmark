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

    acc (recall)    = |expected & found| / |expected|   -- did it find everything?
    noise (excess)  = |found - expected| / |found|       -- did it add things that
                                                              aren't there?
    exact_match     = found == expected exactly

These are two independently meaningful numbers, not one blended "correctness" --
a run can have zero noise (invented nothing) and still low acc (found only
part of the true answer), or the reverse (found everything, plus extras).

Questions with no "expected" field, or rows with no structured_output (free-text
questions, or json_schema runs that errored before producing one), are skipped
here -- they still need grade-results.py's manual y/n grading.

Model handling: results.jsonl rows carry a "model" field (run-benchmark.ps1's
-Model, or the literal string "default" when unset; older rows predating that
parameter have no field at all). This script normalizes both "unset" cases to
"default", copies it into every scored row, and groups the console summary by
(app, question_id, model, condition) -- so feeding it a results.jsonl that
mixes models (e.g. a default-Sonnet run and a -Model haiku run appended to the
same file) reports them as separate groups instead of silently blending a
Haiku run's accuracy into a Sonnet run's median. It's still fine to keep
model-specific results files separately if you'd rather not mix them at the
source (run-benchmark.ps1's header used to recommend this as the *only* safe
option, back before this script grouped by model) -- either way scores.jsonl
ends up carrying the model that produced each row.

Guide-context handling: results.jsonl rows can also carry used_mcp_context
(true/false) and mcp_context_file (a path), logged by run-benchmark.ps1 when
a markdown guide describing how to use the CAST Imaging MCP tools is injected
into the prompt on "with"/"with-forced" runs. Both fields used to be silently
dropped here -- present in results.jsonl, absent from scores.jsonl -- so a
"with" bucket could quietly blend guide-assisted and bare-tool-description
runs into one median with no way to tell them apart after the fact. Fixed
now: both fields are copied through raw (see score_row), and the console
summary groups by guide usage the same way it already groups by model, with
three states, not two -- True ("guide"), False ("no-guide"), and missing/None
("n/a", meaning the row predates this field entirely, so guide usage is
genuinely unknown, not confirmed absent).

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
FIELD_PRIORITY = ["tables", "pages", "files", "items", "exercises"]


def _basename(x):
    """Normalize a value to its basename for matching purposes.

    Ground truth for a "pages" question sometimes carries a directory prefix
    ("AjaxRequest/AjaxRequest.aspx", "admin/managermain.aspx") to disambiguate
    from same-named files elsewhere. Models answering the same question
    routinely drop that prefix ("AjaxRequest.aspx") or, less often, add an
    unrelated one back in (a stray repo-root prefix like
    "recipe-main/recipe-main/pmview.aspx" seen in one real run). Comparing
    raw strings scored both of those as a miss + an extra -- i.e. it
    penalized a run twice for a formatting choice, not a substantive error --
    which was confirmed by hand on real data: 9 of 15 "with-forced" runs on
    the PrivateMessage-pages question reported exactly the right 8 pages,
    just without the 3 tricky ones' directory prefix, and scored 5/8 instead
    of 8/8 as a result.

    Matching on basename instead treats those as the same file, which is
    what they are. This is a no-op for non-path values -- a plain identifier
    with no '/' in it (e.g. a SQL table name like "Recipes") is returned
    unchanged, so table-count scoring is completely unaffected; the
    deliberate case-sensitivity from the comment below is preserved too,
    since only the directory prefix is stripped, not the casing.
    """
    return str(x).strip().replace("\\", "/").rsplit("/", 1)[-1]


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

    # "Coverage anchor" test-generation questions (e.g. testgen-*) ask for a
    # list of {name, exercises} test objects instead of a flat array, so the
    # model has to write an actual named test per table rather than just
    # dumping a table list. "name" is free text and is deliberately never
    # scored here -- only "exercises" (one table name per test) needs to
    # feed into the same set-arithmetic scoring every other question already
    # uses. This flattens tests[].exercises into a synthetic top-level
    # "exercises" list so pick_compare_field() below finds it exactly like
    # any other array-valued field. No-op for every existing question, since
    # they don't have a "tests" key at all.
    if isinstance(found.get("tests"), list) and "exercises" not in found:
        found = dict(found)
        found["exercises"] = [
            t.get("exercises") for t in found["tests"]
            if isinstance(t, dict) and t.get("exercises") is not None
        ]

    field = pick_compare_field(expected, found)

    out = {
        "timestamp": row.get("timestamp"),
        "session_id": row.get("session_id"),
        "app": row.get("app"),
        "question_id": row.get("question_id"),
        "condition": row.get("condition"),
        # Normalized, not passed through raw: run-benchmark.ps1 writes the
        # literal string "default" when -Model isn't set, but older rows
        # (recorded before -Model existed) have no "model" key at all, which
        # would land here as None. Coercing both to "default" means every
        # scored row is unambiguous about which model produced it -- no
        # tribal knowledge required that "missing field" == Sonnet -- and,
        # more importantly, means grouping/printing below (and any future
        # consumer of scores.jsonl) can key on model without a separate
        # None-handling branch silently reintroducing the exact blending
        # bug this field exists to prevent.
        "model": row.get("model") or "default",
        "run_index": row.get("run_index"),
        "used_mcp_tool": row.get("used_mcp_tool"),
        "used_json_schema": row.get("used_json_schema"),
        # Passed through RAW, not coerced -- same reasoning as used_json_schema
        # above: True/False/missing are three genuinely different states here,
        # not two. True/False were both logged deliberately by run-benchmark.ps1
        # once this feature existed (False on "without" rows, since there's no
        # CAST context to hand it; True/False on "with"/"with-forced" rows
        # depending on whether -McpContextFile was actually passed). Rows from
        # before this field existed have neither key at all, which lands here
        # as None -- a third, "unknown" cohort, not the same thing as a
        # confirmed False. Silently coercing None to False would make an old
        # run look like a deliberately-verified no-guide run, which it isn't.
        # This is exactly the kind of silent blending that let a fraction of
        # already-reported "with"/"with-forced" rows turn out to have had a
        # guide file loaded without it ever showing up in scores.jsonl -- see
        # mcp_context_file below for the other half of that fix.
        "used_mcp_context": row.get("used_mcp_context"),
        "mcp_context_file": row.get("mcp_context_file"),
        "cost_usd": row.get("cost_usd"),
        "compare_field": field,
    }

    if field:
        # Case-sensitive on purpose (see _basename's docstring for why): these
        # are real SQL identifiers/file names, not prose, so "Recipes" vs
        # "recipes" is a meaningful discrepancy worth surfacing, not noise to
        # normalize away. What IS normalized is the directory prefix on
        # path-like values, via _basename -- matching happens on that
        # normalized key, but "missing"/"extra" below still report the
        # original raw strings so a genuine miss still reads like one.
        expected_raw = [str(x).strip() for x in expected[field]]
        found_raw = [str(x).strip() for x in found[field]]
        expected_by_key = {_basename(x): x for x in expected_raw}
        found_by_key = {_basename(x): x for x in found_raw}

        matched_keys = set(expected_by_key) & set(found_by_key)
        missing_keys = set(expected_by_key) - set(found_by_key)
        extra_keys = set(found_by_key) - set(expected_by_key)
        missing = {expected_by_key[k] for k in missing_keys}
        extra = {found_by_key[k] for k in extra_keys}

        # Kept separately, not folded into "matched" silently: a match that
        # only worked because of basename normalization means the model's
        # own string didn't literally equal ground truth. Worth being able
        # to audit whether that's a one-off or a systematic path-format
        # habit -- e.g. a schema "description" field worth tightening.
        normalized_matches = sorted(
            f"{found_by_key[k]} -> {expected_by_key[k]}"
            for k in matched_keys
            if found_by_key[k] != expected_by_key[k]
        )

        out["expected_count"] = len(expected_by_key)
        out["found_count"] = len(found_by_key)
        out["matched_count"] = len(matched_keys)
        out["missing"] = sorted(missing)
        out["extra"] = sorted(extra)
        if normalized_matches:
            out["normalized_matches"] = normalized_matches
        # acc = recall: what fraction of the true answer did it find.
        # noise = 1 - precision: what fraction of what it said was extra.
        # Rounded to 4dp for a readable jsonl -- full precision isn't
        # meaningful here anyway (these are ratios of small integer counts).
        out["acc"] = round(len(matched_keys) / len(expected_by_key), 4) if expected_by_key else None
        out["noise"] = round(len(extra_keys) / len(found_by_key), 4) if found_by_key else 0.0
        out["exact_match"] = (not missing_keys) and (not extra_keys)
    else:
        out["acc"] = None
        out["noise"] = None
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

    # Grouped by model AND guide-context usage (not just app/question/condition):
    # model-mixing is the hazard run-benchmark.ps1's own header warns about;
    # guide-mixing is the same hazard for -McpContextFile. A "with"/"with-forced"
    # bucket that silently blends guide-assisted and bare-tool-description runs
    # would report one median that isn't really describing either treatment --
    # this three-state label keeps them apart instead. "n/a" is its own bucket,
    # not folded into "no": it means the row predates this field entirely, so
    # whether a guide was used is genuinely unknown, not confirmed absent.
    def _mcp_context_label(v):
        if v is True:
            return "guide"
        if v is False:
            return "no-guide"
        return "n/a"  # field missing entirely -- row predates -McpContextFile

    groups = defaultdict(list)
    for s in scored:
        key = (s["app"], s["question_id"], s["model"], s["condition"],
               _mcp_context_label(s.get("used_mcp_context")))
        groups[key].append(s)

    header = (
        f"{'app':<14}{'question':<28}{'model':<9}{'condition':<12}{'guide':<9}{'n':<4}"
        f"{'exact':<8}{'median acc':<12}{'median noise':<13}{'mcp used':<10}"
    )
    print()
    print(header)
    print("-" * len(header))
    for (app, qid, model, cond, guide), rows in sorted(groups.items()):
        exact = sum(1 for r in rows if r["exact_match"])
        accs = [r["acc"] for r in rows if r["acc"] is not None]
        noises = [r["noise"] for r in rows if r["noise"] is not None]
        mcp = [r for r in rows if r.get("used_mcp_tool") is not None]
        mcp_str = f"{sum(1 for r in mcp if r['used_mcp_tool'])}/{len(mcp)}" if mcp else "n/a"
        med_acc = f"{statistics.median(accs):.0%}" if accs else "n/a"
        med_noise = f"{statistics.median(noises):.0%}" if noises else "n/a"
        print(f"{app:<14}{qid:<28}{model:<9}{cond:<12}{guide:<9}{len(rows):<4}{exact}/{len(rows):<7}{med_acc:<12}{med_noise:<13}{mcp_str:<10}")


if __name__ == "__main__":
    main()