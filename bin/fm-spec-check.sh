#!/usr/bin/env bash
# fm-spec-check.sh - enforce useful-content-first structure in specs and docs.
#
# Usage:
#   bin/fm-spec-check.sh [--previous <file>] <file>
#   bin/fm-spec-check.sh --help
#
# Supported inputs are .html and .md files.
# The first H1 is treated as a document title only when it is not classified.
# A document must have a substantive heading after that optional title.
# Human-facing HTML with substantive headings must contain an inline <svg> or <table>.
# A headingless HTML redirect stub passes only when it is short, linked, and explicit.
# --previous fails a visual-count decrease without a structured removal note.
#
# Heading pattern list (single owner; extend one expression here):
#   status       - publication/current status and what ships now
#   changelog    - changelog, revision log, and release notes
#   what-changed - what changed and changes since/in/from a point
#   history      - history and rejected alternatives
#   research     - comparative/background research and prior art
#   meta         - document control, authorship, sources, and methodology
#
# Trailing record structure (single owner):
#   A classified heading owns deeper headings until an unclassified heading at
#   the same or a shallower level reopens substantive content.
#   In HTML, headings that remain inside the nearest enclosing <section> of a
#   classified heading are record content regardless of level.
#   id="record", data-role="meta-history", and class="before-archive" are
#   optional record-container hints, not required authoring markup.
#
# Removal note format (single owner):
#   Removed item: <name>. Reason: <stale|out of date|incorrect>. Evidence: <evidence>
set -eu

STATUS_RE='(?:document|publication|release|project|implementation|design)\s+status|status|status\s+(?:of\s+(?:this|the)\s+(?:spec|document|page|report)|and|report|update|today|now|right\s+now)\b.*|status\s*[,:(-]\s*.*|current\s+(?:status|state)|what\s+ships\s+(?:today|now)\b.*'
CHANGELOG_RE='change\s*log\b.*|revision\s+log\b.*|release\s+notes\b.*'
WHAT_CHANGED_RE="what(?:'s|\s+has)?\s+changed\b.*|changes(?:\s+(?:since|in|from)\b.*)?"
HISTORY_RE='history|history\s+(?:of\s+(?:this|the)\s+(?:spec|document|page|report)|and\s+(?:rationale|decisions|changes))\b.*|(?:decision|design|document|implementation|project|revision|version)\s+history\b.*|rejected\s+alternatives?\b.*'
RESEARCH_RE='(?:background|comparative|competitive|competitor|market|prior)\s+research\b.*|prior\s+art\b.*|competitor\s+(?:analysis|comparison)\b.*|how\s+(?:(?:a|the)\s+competitor|yazs)\s+does\s+it\b.*'
META_RE='metadata|document\s+meta(?:data)?|about\s+(?:this|the)\s+document\b.*|document\s+(?:control|information|record)\b.*|authors?|ownership|last\s+updated|what\s+is\s+on\s+this\s+page\b.*|sources(?:\s+and\s+(?:methods?|methodology|provenance))?|references'
REMOVAL_NOTE_RE='removed\s+(?:item|visual)\s*:.{1,300}?\breason\s*:\s*(?:stale|out\s+of\s+date|incorrect)\b.{1,500}?\bevidence\s*:\s*\S'

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

PREVIOUS=
if [ "${1:-}" = "--previous" ]; then
  if [ "$#" -ne 3 ]; then
    usage
    exit 1
  fi
  PREVIOUS=$2
  shift 2
  if [ ! -f "$PREVIOUS" ]; then
    printf 'fm-spec-check: previous file not found: %s\n' "$PREVIOUS" >&2
    exit 1
  fi
fi

if [ "$#" -ne 1 ]; then
  usage
  exit 1
fi

FILE=$1
if [ ! -f "$FILE" ]; then
  printf 'fm-spec-check: file not found: %s\n' "$FILE" >&2
  exit 1
fi

case "${FILE##*.}" in
  html|HTML) KIND=html ;;
  md|MD) KIND=markdown ;;
  *)
    printf 'fm-spec-check: unsupported file type (expected .html or .md): %s\n' "$FILE" >&2
    exit 1
    ;;
esac

if ! command -v python3 >/dev/null 2>&1; then
  printf 'fm-spec-check: python3 is required\n' >&2
  exit 1
fi

exec python3 - "$FILE" "$KIND" "$PREVIOUS" \
  "$STATUS_RE" "$CHANGELOG_RE" "$WHAT_CHANGED_RE" \
  "$HISTORY_RE" "$RESEARCH_RE" "$META_RE" "$REMOVAL_NOTE_RE" <<'PY'
from __future__ import annotations

import html
import json
import re
import sys
from html.parser import HTMLParser
from pathlib import Path


class HeadingParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.headings: list[tuple[int, str, bool, tuple[int, ...]]] = []
        self.level: int | None = None
        self.parts: list[str] = []
        self.heading_in_record = False
        self.record_depth = 0
        self.number_depth = 0
        self.body_depth = 0
        self.hidden_depth = 0
        self.body_parts: list[str] = []
        self.link_count = 0
        self.next_section = 0
        self.sections: list[int] = []
        self.stack: list[
            tuple[str, bool, bool, bool, bool, int | None]
        ] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        lowered = tag.lower()
        attributes = {name.lower(): value or "" for name, value in attrs}
        classes = set(attributes.get("class", "").split())
        record_marker = (
            lowered == "section"
            and (
                attributes.get("id", "").casefold() == "record"
                or attributes.get("data-role", "").casefold() == "meta-history"
            )
        ) or "before-archive" in classes
        number_marker = (
            self.level is not None and lowered == "span" and "num" in classes
        )
        body_marker = lowered == "body"
        hidden_marker = self.body_depth > 0 and lowered in {"script", "style"}
        section_marker = None
        if lowered == "section":
            self.next_section += 1
            section_marker = self.next_section
            self.sections.append(section_marker)
        self.stack.append(
            (
                lowered,
                record_marker,
                number_marker,
                body_marker,
                hidden_marker,
                section_marker,
            )
        )
        self.record_depth += int(record_marker)
        self.number_depth += int(number_marker)
        self.body_depth += int(body_marker)
        self.hidden_depth += int(hidden_marker)
        if self.body_depth and lowered == "a" and attributes.get("href"):
            self.link_count += 1
        if lowered in {"h1", "h2", "h3"}:
            self.level = int(lowered[1])
            self.parts = []
            self.heading_in_record = self.record_depth > 0

    def handle_startendtag(
        self, tag: str, attrs: list[tuple[str, str | None]]
    ) -> None:
        self.handle_starttag(tag, attrs)
        self.handle_endtag(tag)

    def handle_endtag(self, tag: str) -> None:
        lowered = tag.lower()
        if self.level is not None and lowered == f"h{self.level}":
            self.headings.append(
                (
                    self.level,
                    "".join(self.parts).strip(),
                    self.heading_in_record,
                    tuple(self.sections),
                )
            )
            self.level = None
            self.parts = []
            self.heading_in_record = False
        matching = next(
            (
                index
                for index in range(len(self.stack) - 1, -1, -1)
                if self.stack[index][0] == lowered
            ),
            None,
        )
        if matching is None:
            return
        for _, record, number, body, hidden, section in reversed(
            self.stack[matching:]
        ):
            self.record_depth -= int(record)
            self.number_depth -= int(number)
            self.body_depth -= int(body)
            self.hidden_depth -= int(hidden)
            if section is not None:
                self.sections.pop()
        del self.stack[matching:]

    def handle_data(self, data: str) -> None:
        if self.level is not None and self.number_depth == 0:
            self.parts.append(data)
        if self.body_depth > 0 and self.hidden_depth == 0 and data.strip():
            self.body_parts.append(" ".join(data.split()))


def markdown_headings(source: str) -> list[tuple[int, str, bool, tuple[int, ...]]]:
    headings: list[tuple[int, str, bool, tuple[int, ...]]] = []
    fence_char: str | None = None
    fence_length = 0
    setext_candidate: str | None = None
    for line in source.splitlines():
        fence = re.match(r"^\s{0,3}(`{3,}|~{3,})", line)
        if fence:
            marker = fence.group(1)
            if fence_char is None:
                fence_char = marker[0]
                fence_length = len(marker)
            elif marker[0] == fence_char and len(marker) >= fence_length:
                fence_char = None
                fence_length = 0
            setext_candidate = None
            continue
        if fence_char is not None:
            continue
        setext = re.match(r"^\s{0,3}(=+|-+)\s*$", line)
        if setext:
            if setext_candidate is not None:
                level = 1 if setext.group(1)[0] == "=" else 2
                headings.append((level, setext_candidate, False, ()))
            setext_candidate = None
            continue
        match = re.match(r"^\s{0,3}(#{1,3})[ \t]+(.+?)\s*$", line)
        if match:
            text = re.sub(r"[ \t]+#+[ \t]*$", "", match.group(2)).strip()
            headings.append((len(match.group(1)), text, False, ()))
            setext_candidate = None
            continue
        stripped = line.strip()
        indentation = len(line) - len(line.lstrip())
        setext_candidate = (
            stripped
            if stripped
            and indentation <= 3
            and not re.match(r"^(?:>|[-+*]\s|\d+[.)]\s)", stripped)
            else None
        )
    return headings


def normalize_heading(value: str) -> str:
    value = html.unescape(value)
    value = re.sub(r"<[^>]+>", " ", value)
    value = re.sub(r"!?\[([^\]]+)\]\([^)]*\)", r"\1", value)
    value = value.replace("`", "").replace("*", "").replace("_", "")
    value = value.replace("’", "'").replace("‘", "'")
    value = re.sub(r"^\s*(?:\d{2}|\d[A-Z])(?=[A-Z][a-z])", "", value)
    value = re.sub(r"^\s*\d+(?:\.\d+)*[.):]?\s+", "", value)
    value = re.sub(r"^\s*[•·]\s*", "", value)
    value = re.sub(r"[\s:.-]+$", "", value.strip())
    return re.sub(r"\s+", " ", value).casefold()


path = Path(sys.argv[1])
kind = sys.argv[2]
previous_path = Path(sys.argv[3]) if sys.argv[3] else None
pattern_names = ("status", "changelog", "what-changed", "history", "research", "meta")
patterns = [re.compile(rf"^(?:{value})$", re.IGNORECASE) for value in sys.argv[4:10]]
removal_note_pattern = re.compile(sys.argv[10], re.IGNORECASE | re.DOTALL)

try:
    source = path.read_text(encoding="utf-8")
except (OSError, UnicodeDecodeError) as exc:
    print(f"fm-spec-check: cannot read {path}: {exc}", file=sys.stderr)
    raise SystemExit(1)

if kind == "html":
    parser = HeadingParser()
    parser.feed(source)
    parser.close()
    headings = parser.headings
else:
    headings = markdown_headings(source)

body_text = ""
redirect_stub = False
if kind == "html":
    body_text = " ".join(parser.body_parts)
    redirect_stub = (
        not headings
        and 1 <= parser.link_count <= 2
        and len(body_text) <= 500
        and re.search(
            r"\b(?:archived?|moved|redirect(?:ed|ion)?|now\s+lives)\b",
            body_text,
            re.IGNORECASE,
        )
        is not None
    )


def classification(value: str) -> str | None:
    normalized = normalize_heading(value)
    for name, pattern in zip(pattern_names, patterns):
        if pattern.fullmatch(normalized):
            return name
    return None


classes = [classification(text) for _, text, _, _ in headings]
effective_classes: list[str | None] = []
record_level: int | None = None
record_sections: set[int] = set()
for heading_class, (level, _, in_record, sections) in zip(classes, headings):
    nested_by_level = record_level is not None and level > record_level
    nested_by_section = any(section in record_sections for section in sections)
    if in_record or nested_by_level or nested_by_section:
        effective_classes.append(heading_class or "meta")
        continue
    effective_classes.append(heading_class)
    if heading_class is None:
        record_level = None
        continue
    record_level = level
    if sections:
        record_sections.add(sections[-1])

title_index = (
    0
    if headings and headings[0][0] == 1 and effective_classes[0] is None
    else None
)
content_indices = [index for index in range(len(headings)) if index != title_index]
first_substantive = next(
    (index for index in content_indices if effective_classes[index] is None),
    None,
)
findings: list[tuple[str, str, str]] = []

if first_substantive is None and not redirect_stub:
    findings.append(
        (
            "<document>",
            "substantive-heading-required",
            "document has no substantive heading after the optional title",
        )
    )

for index in content_indices:
    heading_class = effective_classes[index]
    if heading_class is None:
        continue
    if first_substantive is None or index < first_substantive:
        findings.append(
            (
                headings[index][1],
                "useful-content-first",
                f"{heading_class} heading appears before the first substantive heading",
            )
        )
    if any(
        later > index and effective_classes[later] is None
        for later in content_indices
    ):
        findings.append(
            (
                headings[index][1],
                "history-at-end",
                f"{heading_class} heading is followed by substantive content",
            )
        )

if (
    kind == "html"
    and first_substantive is not None
    and not re.search(r"<(?:svg|table)\b", source, re.IGNORECASE)
):
    findings.append(
        (
            "<document>",
            "human-visual-required",
            "human-facing HTML contains no inline <svg> or <table>",
        )
    )

if previous_path is not None:
    try:
        previous_source = previous_path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        print(f"fm-spec-check: cannot read {previous_path}: {exc}", file=sys.stderr)
        raise SystemExit(1)
    visual_pattern = re.compile(r"<(?:svg|figure|table)\b", re.IGNORECASE)
    previous_visuals = len(visual_pattern.findall(previous_source))
    current_visuals = len(visual_pattern.findall(source))
    removal_note = removal_note_pattern.search(
        re.sub(r"<[^>]+>", " ", html.unescape(source)),
    )
    if current_visuals < previous_visuals and removal_note is None:
        findings.append(
            (
                "<document>",
                "visual-removal-note-required",
                f"visual count fell from {previous_visuals} to {current_visuals} "
                "without a stale-or-incorrect removal note with evidence",
            )
        )

if findings:
    for heading, rule, detail in findings:
        print(
            f"fm-spec-check: FAIL heading {json.dumps(heading)} "
            f"rule {rule}: {detail}"
        )
    raise SystemExit(1)

visual = "n/a"
if kind == "html":
    visual = "redirect" if redirect_stub else "present"
print(f"fm-spec-check: PASS file={path} headings={len(headings)} visual={visual}")
PY
