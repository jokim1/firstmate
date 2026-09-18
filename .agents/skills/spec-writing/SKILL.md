---
name: spec-writing
description: >-
  Agent-only procedure for writing and checking specs, design pages, research reports, how-to guides, references, decision records, status reports, and wiki pages.
  Load before writing, updating, or checking any human-facing spec, design page, research report, how-to guide, reference, decision record, status report, or wiki page, and before scaffolding a brief for one.
  Owns audience format, visual-first presentation, objective-derived structure, useful-content-first ordering, content preservation, trailing document records, and the mandatory structure check.
user-invocable: false
metadata:
  internal: true
---

# Spec writing

Use this procedure to organize a document from its reader's objective instead of from a generic template or the chronology of how the work happened.
It is the single owner of Firstmate's document-writing and document-checking procedure for specs, design pages, research reports, how-to guides, references, decision records, status reports, and wiki pages.
The goal is for a reader to reach the useful answer immediately, understand it visually where possible, and find the historical record without losing it.

## Choose the audience and format

Name the intended reader before drafting.
A document intended for any human reader is a self-contained HTML file.
A document intended only for agents is Markdown.
A Markdown-only human deliverable is a defect, even when the Markdown renderer can display tables or diagrams.

Human-facing HTML includes its own structure and styles rather than depending on an external site theme, stylesheet, script, font, image, or diagram renderer.
Define color, surface, border, text, muted-text, and accent tokens in `:root`, and override those tokens under `@media (prefers-color-scheme: dark)` so the same file works in light and dark environments.
Use semantic HTML for the prose and real inline `<svg>` for diagrams and charts.
Give each SVG a useful `<title>` and `<desc>`, keep labels legible at ordinary browser widths, and retain the underlying values in text or a table when exact lookup matters.

Agent-only Markdown optimizes for precise headings, compact prose, searchable terms, and copyable literals.
Do not spend tokens simulating a visual layout with ASCII decoration when a short table or list communicates the same structure.

## Derive the structure from the objective

Before writing, name the page type and complete this sentence: "The reader opens this page to ___."
Then ask, "What does this reader need first to act?"
That answer determines the opening and the order that follows.
Do not begin from a stored outline and do not force sections that the objective does not need.

Use these page-type procedures as worked examples of the reasoning, not as rigid templates.

### Design spec

Open with the design objective or objectives, then explain the proposed design as quickly as possible.
Show the system, player experience, or interaction model visually before expanding into rules, interfaces, edge cases, and validation.
Worked example: a passive-skill-tree page opens with the progression goals, shows the tree and unlock flow, explains node rules and balance constraints, gives examples, and ends with one document-record section.

### Research report

Open with the research objective, follow it with a compact overview of the results, and only then present evidence and detailed findings.
Put the most decision-relevant result first rather than narrating the search process.
Worked example: a retention study opens with the question it tested, shows a chart and three-result summary, breaks down the evidence and limitations, and ends with sources, comparative research, and the document record.

### How-to

Open with the steps the reader should perform.
Move prerequisites ahead of a step only when the reader cannot safely begin without them, then provide a success check and troubleshooting for likely failure points.
Worked example: a credential-rotation guide opens with the ordered rotation commands, shows the old-to-new handoff flow, verifies the new credential, covers recovery, and ends with the document record.

### Reference

Open with the lookup surface the reader came to use, organized by the task, object, command, or field they already know.
Put definitions and exact values in tables, follow them with examples and edge cases, and avoid an introductory essay.
Worked example: an event-schema reference opens with the field table and event relationship diagram, then gives valid examples and constraints, and ends with the document record.

### Decision record

Open with the decision and its practical effect.
Follow with the reasons and evidence needed to trust or implement it, then consequences and required actions.
Worked example: a storage decision opens with "Use SQLite for local durable state," shows the decision forces and resulting component boundary, explains consequences and rollout, and puts rejected alternatives and decision history in the trailing document record.

### Status report

Open with the current outcome and health of the work, then show progress against the objective, risks, owners, and next actions.
Use outcome-oriented headings such as `Outcome now` or `Health at a glance` instead of a throat-clearing `Status` heading.
Worked example: a launch report opens with the launch outcome and a red-amber-green table, shows milestone movement and blockers, names next actions, and ends with publication metadata and update history in the document record.

## Make human pages visual first

Whenever the content contains a quantity, relationship, flow, sequence, comparison, state change, hierarchy, or spatial arrangement, render that information as a chart, graph, table, or diagram before or instead of explaining it in prose.
Use the visual to carry information, not to decorate the page.
Lead with the visual, add a short interpretation, and reserve prose for implications, exceptions, and detail the visual cannot carry.

Choose the form from the relationship being explained:

- Use line charts for change over time and bar charts for magnitude or category comparisons.
- Use tables when readers need exact values, attribute comparisons, matrices, or quick lookup.
- Use flowcharts for choices and process flow, and sequence diagrams for ordered interaction between actors or systems.
- Use node-link diagrams for dependencies and networks, and trees for hierarchy or progression.
- Use state diagrams for allowed states and transitions.
- Use timelines for milestones and event order.
- Use labeled schematics or wireframes for spatial layout and interface composition.

An HTML page must contain at least one real inline `<svg>` or `<table>`, but that is only the floor.
One token visual does not satisfy the procedure when the page contains other relationships that prose still hides.

## Preserve value during updates

For every update or consolidation, compare the draft with the previous version and inventory each existing visual, table, figure, worked example, and substantive detail.
Keep every inventoried item unless evidence shows that it is out of date or incorrect.
Restructuring moves content to the place where it serves the reader; it never silently drops content.
When an out-of-date or incorrect item must be removed, record it in the trailing document record using the removal-note format owned by the header of `bin/fm-spec-check.sh`.
Give every removed item its own removal-note entry so a checker can reconcile the list against the previous version.

For an update, run `bin/fm-spec-check.sh --previous <previous-file> <file>`.
The optional comparison fails when the combined inline `<svg>`, `<figure>`, and `<table>` count decreases without a structured removal note.
That count is only a deterministic warning floor; it cannot prove that every visual or piece of information survived.

## Put useful content first

Every page type obeys one invariant: substantive, actionable content comes before document history and meta context.
All publication status, changelog, "what changed," decision history, rejected alternatives, comparative research, and document metadata belong in one trailing section after the substantive content.
Keep that material and move it intact rather than deleting or summarizing it away.
The trailing section may use classified subsections when the record needs them, but no substantive section may follow it.
Use ordinary heading nesting or a semantic section for the trailing record; the exact structural signals recognized by the checker are owned by the header of `bin/fm-spec-check.sh`.

Reject these slop patterns by name:

- **Status-first throat clearing** opens with publication state instead of the answer.
- **Changelog-first archaeology** makes the reader reconstruct the current design from revisions.
- **What-changed stack** repeats change summaries before explaining what exists now.
- **Research detour** puts competitor, comparative, background, or prior-art research ahead of the page's own result or design.
- **Meta preamble** leads with owners, dates, versions, approvals, or document-control fields.
- **Prose wall** describes a quantity, relationship, flow, sequence, or comparison that should be visual.
- **Fake visual** uses decorative boxes, Mermaid source, or CSS ornament where the delivered HTML needs a rendered inline SVG or a real table.
- **Template cargo cult** includes sections because a prior document had them rather than because this reader needs them.
- **Silent consolidation loss** removes a visual, example, or useful detail while reorganizing the page without proving that it is stale or incorrect.

## Writer self-check

Before declaring the document done:

1. State the audience, page type, page objective, and the first thing its reader needs to act.
2. Confirm the opening supplies that thing without status, history, research detours, or document metadata in front of it.
3. Inventory every quantity, relationship, flow, sequence, comparison, state change, hierarchy, and spatial arrangement, and confirm each has the appropriate visual form in a human-facing page.
4. Confirm a human-facing page is self-contained HTML with light and dark tokens and real inline SVG or tables, and an agent-only page is Markdown.
5. For an update or consolidation, reconcile every prior visual, table, figure, worked example, and substantive detail, and add an evidenced removal entry for each stale or incorrect item that was removed.
6. Confirm all historical and meta material remains present in one contiguous trailing section.
7. Run `bin/fm-spec-check.sh <file>`, or run it with `--previous <previous-file>` for an update, and fix every finding before reporting completion.

The checker is a structural floor, not a substitute for this semantic review.

## Independent checker contract

Every independent checker runs `bin/fm-spec-check.sh <file>` before issuing a verdict, using `--previous <previous-file>` for an update or consolidation.
If the command fails, the checker must fail the page and name the reported rule instead of waiving it because the content is otherwise correct.
After a structural failure, the checker still reviews the substance and reports those findings separately.
Review non-destructively: verify that nothing current was lost, every new requirement is present, and remediation moves historical material rather than cutting it.
Both independent checkers compare the page with its previous version and verify every removed visual, table, figure, worked example, and detail against the removal list and its evidence.
An unexplained removal is a checker failure, even when the deterministic visual counts do not decrease.
Passing the command does not excuse a prose wall, a misleading visual, the wrong page objective, missing current behavior, or missing required detail.
