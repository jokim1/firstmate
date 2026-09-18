#!/usr/bin/env bash
# Behavioral regressions for useful-content-first spec structure checks.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-spec-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-spec-check)

run_check() {
  local file=$1
  local output_file=$2
  set +e
  "$CHECK" "$file" >"$output_file" 2>&1
  CHECK_RC=$?
  set -e
}

run_check_with_previous() {
  local previous=$1
  local file=$2
  local output_file=$3
  set +e
  "$CHECK" --previous "$previous" "$file" >"$output_file" 2>&1
  CHECK_RC=$?
  set -e
}

test_passing_html_spec() {
  local file="$TMP_ROOT/design.html"
  local output="$TMP_ROOT/design.out"
  cat >"$file" <<'HTML'
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Progression design</title></head>
<body>
<h1>Progression design</h1>
<h2>Design objectives</h2>
<p>Make the next useful choice visible.</p>
<svg viewBox="0 0 120 40"><title>Unlock flow</title><desc>Start leads to a choice.</desc><path d="M5 20h110"/></svg>
<h2>System model</h2>
<p>Nodes unlock from left to right.</p>
<h2>Document record</h2>
<h3>Status</h3>
<p>Approved.</p>
</body>
</html>
HTML
  run_check "$file" "$output"
  [ "$CHECK_RC" -eq 0 ] || fail "visual HTML spec failed: $(cat "$output")"
  assert_grep 'fm-spec-check: PASS' "$output" "passing HTML did not report PASS"
  pass "spec check accepts a visual HTML design with a trailing document record"
}

test_passing_markdown_research_report() {
  local file="$TMP_ROOT/research.md"
  local output="$TMP_ROOT/research.out"
  cat >"$file" <<'MD'
# Retention study

## Objective

Identify which onboarding step predicts a second session.

## Results overview

Completing the first build is the strongest predictor.

## Detailed findings

The effect remains after segmenting by acquisition source.

## Sources and methodology

The cohort contains new accounts from the last complete week.
MD
  run_check "$file" "$output"
  [ "$CHECK_RC" -eq 0 ] || fail "Markdown research report failed: $(cat "$output")"
  pass "spec check accepts objective-first Markdown research for agent readers"
}

test_slop_shape_fails_useful_content_first() {
  local file="$TMP_ROOT/slop.html"
  local output="$TMP_ROOT/slop.out"
  cat >"$file" <<'HTML'
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Passive skill tree</title></head>
<body>
<h1>Passive skill tree</h1>
<h2><span class="num">00</span>Status of this spec</h2>
<p>Draft.</p>
<h2><span class="num">0A</span>What changed in this revision</h2>
<p>Several nodes moved.</p>
<h2><span class="num">01</span>What ships today, and why it is not better enough</h2>
<p>The prototype has three clusters.</p>
<h2><span class="num">02</span>How YAZS does it (PC reference)</h2>
<p>Another game uses clusters.</p>
<h2><span class="num">03</span>Comparative research</h2>
<p>Another game uses clusters.</p>
<h2><span class="num">04</span>Design objectives</h2>
<p>Make progression legible.</p>
<svg viewBox="0 0 20 20"><title>Tree</title><desc>Two linked nodes.</desc><path d="M1 10h18"/></svg>
</body>
</html>
HTML
  run_check "$file" "$output"
  [ "$CHECK_RC" -eq 1 ] || fail "slop-shaped page unexpectedly passed"
  assert_grep 'heading "Status of this spec" rule useful-content-first' "$output" \
    "status-first finding did not name its heading and rule"
  assert_grep 'heading "What changed in this revision" rule useful-content-first' "$output" \
    "what-changed finding did not name its heading and rule"
  assert_grep 'heading "What ships today, and why it is not better enough" rule useful-content-first' "$output" \
    "what-ships finding did not name its heading and rule"
  assert_grep 'heading "How YAZS does it (PC reference)" rule history-at-end' "$output" \
    "competitor finding did not name its heading and rule"
  assert_grep 'heading "Comparative research" rule history-at-end' "$output" \
    "research-detour finding did not name its heading and rule"
  pass "spec check rejects real numbered-span status, change, and research throat clearing"
}

test_numbered_meta_preamble_fails() {
  local file="$TMP_ROOT/meta-preamble.html"
  local output="$TMP_ROOT/meta-preamble.out"
  cat >"$file" <<'HTML'
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Cards and specials</title></head>
<body>
<h1>Cards and specials</h1>
<h2><span class="num">00</span>What is on this page</h2>
<p>This page contains the design and its history.</p>
<h2><span class="num">01</span>Loadout rules</h2>
<table><tr><th>Slot</th><th>Rule</th></tr><tr><td>One</td><td>Active</td></tr></table>
</body>
</html>
HTML
  run_check "$file" "$output"
  [ "$CHECK_RC" -eq 1 ] || fail "numbered meta preamble unexpectedly passed"
  assert_grep 'heading "What is on this page" rule useful-content-first' "$output" \
    "numbered meta preamble did not name its heading and rule"
  pass "spec check rejects a numbered-span meta preamble"
}

test_history_in_middle_fails() {
  local file="$TMP_ROOT/history-middle.md"
  local output="$TMP_ROOT/history-middle.out"
  cat >"$file" <<'MD'
# Progression design

## Design objective

Make build choices legible.

## Decision history

The first draft used linear tiers.

## Node rules

Each node has one cost and one effect.
MD
  run_check "$file" "$output"
  [ "$CHECK_RC" -eq 1 ] || fail "history in the middle unexpectedly passed"
  assert_grep 'heading "Decision history" rule history-at-end' "$output" \
    "middle-history finding did not name its heading and rule"
  pass "spec check rejects history followed by substantive content"
}

test_sources_and_provenance_in_middle_fails() {
  local file="$TMP_ROOT/provenance-middle.md"
  local output="$TMP_ROOT/provenance-middle.out"
  cat >"$file" <<'MD'
# Progression design

## Design objective

Make build choices legible.

## Sources and provenance

The source is the current tuning sheet.

## Node rules

Each node has one cost and one effect.
MD
  run_check "$file" "$output"
  [ "$CHECK_RC" -eq 1 ] || fail "sources and provenance in the middle unexpectedly passed"
  assert_grep 'heading "Sources and provenance" rule history-at-end' "$output" \
    "sources-and-provenance finding did not name its heading and rule"
  pass "spec check classifies sources and provenance as trailing metadata"
}

test_html_without_visual_fails() {
  local file="$TMP_ROOT/no-visual.html"
  local output="$TMP_ROOT/no-visual.out"
  cat >"$file" <<'HTML'
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Progression design</title></head>
<body>
<h1>Progression design</h1>
<h2>Design objective</h2>
<p>Make build choices legible.</p>
</body>
</html>
HTML
  run_check "$file" "$output"
  [ "$CHECK_RC" -eq 1 ] || fail "HTML without visuals unexpectedly passed"
  assert_grep 'heading "<document>" rule human-visual-required' "$output" \
    "missing-visual finding did not name its document heading and rule"
  pass "spec check rejects human HTML with no inline SVG or table"
}

test_missing_substantive_heading_fails() {
  local empty_md="$TMP_ROOT/empty.md"
  local headingless_md="$TMP_ROOT/headingless.md"
  local title_only_md="$TMP_ROOT/title-only.md"
  local headingless_html="$TMP_ROOT/headingless.html"
  local output="$TMP_ROOT/no-substantive-heading.out"
  local file

  : >"$empty_md"
  printf 'A paragraph without a heading.\n' >"$headingless_md"
  printf '# Document title\n' >"$title_only_md"
  cat >"$headingless_html" <<'HTML'
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Lookup</title></head>
<body>
<p>A table is visual but does not provide document structure.</p>
<table><tr><th>Key</th><th>Value</th></tr><tr><td>A</td><td>B</td></tr></table>
</body>
</html>
HTML

  for file in "$empty_md" "$headingless_md" "$title_only_md" "$headingless_html"; do
    run_check "$file" "$output"
    [ "$CHECK_RC" -eq 1 ] || fail "$(basename "$file") unexpectedly passed without a substantive heading"
    assert_grep 'heading "<document>" rule substantive-heading-required' "$output" \
      "$(basename "$file") did not fail the substantive-heading rule"
  done
  pass "spec check rejects empty, headingless, and title-only documents"
}

test_preserved_archive_passes() {
  local file="$TMP_ROOT/preserved-archive.html"
  local output="$TMP_ROOT/preserved-archive.out"
  cat >"$file" <<'HTML'
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Progression design</title></head>
<body>
<h1>Progression design</h1>
<section><h2>Design objective</h2><p>Make choices legible.</p>
<table><tr><th>Choice</th><th>Effect</th></tr><tr><td>A</td><td>B</td></tr></table></section>
<section>
<h2>Document record</h2>
<p>The superseded original is preserved intact below.</p>
<div>
<h1>Original design</h1>
<h2>Decision history</h2>
<h2>Skill trees</h2>
</div>
</section>
</body>
</html>
HTML
  run_check "$file" "$output"
  [ "$CHECK_RC" -eq 0 ] || fail "preserved archive failed: $(cat "$output")"
  pass "spec check keeps an ordinary section's nested archive inside the trailing record"
}

test_markdown_record_nesting_passes() {
  local file="$TMP_ROOT/nested-record.md"
  local output="$TMP_ROOT/nested-record.out"
  cat >"$file" <<'MD'
# Progression design

## Design objective

Make choices legible.

## Document record

The superseded original is preserved intact below.

### Original design

The old design remains available as history.

### Skill trees

The old skill-tree detail remains available as history.
MD
  run_check "$file" "$output"
  [ "$CHECK_RC" -eq 0 ] || fail "nested Markdown record failed: $(cat "$output")"
  pass "spec check keeps deeper Markdown headings inside the trailing record"
}

test_same_level_after_record_fails() {
  local file="$TMP_ROOT/record-then-content.md"
  local output="$TMP_ROOT/record-then-content.out"
  cat >"$file" <<'MD'
# Progression design

## Design objective

Make choices legible.

## Document record

### Original design

The old design remains available as history.

## Node rules

Each node has one cost and one effect.
MD
  run_check "$file" "$output"
  [ "$CHECK_RC" -eq 1 ] || fail "same-level content after the record unexpectedly passed"
  assert_grep 'heading "Document record" rule history-at-end' "$output" \
    "same-level reopening did not name the record heading and rule"
  pass "spec check rejects same-level substantive content after the record"
}

test_redirect_stub_passes() {
  local file="$TMP_ROOT/redirect.html"
  local output="$TMP_ROOT/redirect.out"
  cat >"$file" <<'HTML'
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Moved page</title></head>
<body><p>Archived into <a href="survivor.html">Skill Trees Spec</a>; all current material now lives there.</p></body>
</html>
HTML
  run_check "$file" "$output"
  [ "$CHECK_RC" -eq 0 ] || fail "redirect stub failed: $(cat "$output")"
  assert_grep 'headings=0 visual=redirect' "$output" \
    "redirect stub did not report its narrow exception"
  pass "spec check accepts a short explicit linked redirect stub"
}

test_legitimate_headings_pass() {
  local file="$TMP_ROOT/legitimate-headings.html"
  local output="$TMP_ROOT/legitimate-headings.out"
  cat >"$file" <<'HTML'
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Combat findings</title></head>
<body>
<h1>Combat findings</h1>
<h2>Status overlap edges</h2>
<h2>Status effects</h2>
<h2>Meta</h2>
<h2>Research</h2>
<h2>How the tree does it</h2>
<h2>Research findings</h2>
<h2>Sources of damage</h2>
<h2>Match History</h2>
<table><tr><th>Source</th><th>Damage</th></tr><tr><td>Shot</td><td>10</td></tr></table>
</body>
</html>
HTML
  run_check "$file" "$output"
  [ "$CHECK_RC" -eq 0 ] || fail "legitimate headings failed: $(cat "$output")"
  pass "spec check avoids known category-word false positives"
}

test_setext_markdown_passes() {
  local file="$TMP_ROOT/setext.md"
  local output="$TMP_ROOT/setext.out"
  cat >"$file" <<'MD'
Progression design
==================

Design objective
----------------

Make build choices legible.
MD
  run_check "$file" "$output"
  [ "$CHECK_RC" -eq 0 ] || fail "Setext Markdown failed: $(cat "$output")"
  assert_grep 'headings=2 visual=n/a' "$output" \
    "Setext Markdown headings were not extracted"
  pass "spec check accepts Setext Markdown headings"
}

test_visual_removal_requires_note() {
  local previous="$TMP_ROOT/previous.html"
  local without_note="$TMP_ROOT/without-note.html"
  local with_note="$TMP_ROOT/with-note.html"
  local output="$TMP_ROOT/visual-removal.out"
  cat >"$previous" <<'HTML'
<!doctype html><html lang="en"><body>
<h1>System design</h1><h2>Design objective</h2>
<figure><svg viewBox="0 0 20 20"><title>Flow</title><desc>A flow.</desc></svg></figure>
<table><tr><th>Rule</th></tr><tr><td>A</td></tr></table>
</body></html>
HTML
  cat >"$without_note" <<'HTML'
<!doctype html><html lang="en"><body>
<h1>System design</h1><h2>Design objective</h2>
<table><tr><th>Rule</th></tr><tr><td>A</td></tr></table>
<section id="record"><h2>Document record</h2><p>Updated today.</p></section>
</body></html>
HTML
  cat >"$with_note" <<'HTML'
<!doctype html><html lang="en"><body>
<h1>System design</h1><h2>Design objective</h2>
<table><tr><th>Rule</th></tr><tr><td>A</td></tr></table>
<section id="record"><h2>Document record</h2>
<p>Removed item: Dependency flow. Reason: stale. Evidence: The interface was removed in commit abc123.</p>
</section>
</body></html>
HTML

  run_check_with_previous "$previous" "$without_note" "$output"
  [ "$CHECK_RC" -eq 1 ] || fail "visual count decrease without a note unexpectedly passed"
  assert_grep 'heading "<document>" rule visual-removal-note-required' "$output" \
    "visual decrease did not name the removal-note rule"

  run_check_with_previous "$previous" "$with_note" "$output"
  [ "$CHECK_RC" -eq 0 ] || fail "evidenced visual removal failed: $(cat "$output")"
  pass "spec check requires an evidenced note when visual count decreases"
}

test_passing_html_spec
test_passing_markdown_research_report
test_slop_shape_fails_useful_content_first
test_numbered_meta_preamble_fails
test_history_in_middle_fails
test_sources_and_provenance_in_middle_fails
test_html_without_visual_fails
test_missing_substantive_heading_fails
test_preserved_archive_passes
test_markdown_record_nesting_passes
test_same_level_after_record_fails
test_redirect_stub_passes
test_legitimate_headings_pass
test_setext_markdown_passes
test_visual_removal_requires_note
