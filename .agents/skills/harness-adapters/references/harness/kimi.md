# Kimi Code

Verified on 2026-07-25 with Kimi Code CLI 0.29.1.
Kimi Code 0.42.0 on tmux submitted both idle input and `/exit` on 2026-09-14, while the same harness exposed Herdr's backend-wide split-submission defect.
The corrected Herdr adapter was reverified with Kimi Code 0.42.0 on Herdr 0.8.0.

## Operating facts

| Fact | Value |
|---|---|
| Binary | Absolute executable resolved from `PATH`, then executable `$HOME/.kimi-code/bin/kimi`; spawning refuses if neither exists. |
| Launch | Bare interactive TUI with `--auto`, followed by readiness-gated pointer delivery; positional prompts are rejected. |
| Models | Observed default `kimi-code/kimi-for-coding`, `kimi-code/kimi-for-coding-highspeed`, `kimi-code/k3`, and `kimi-code/k3-256k`; use `kimi provider list --json` for current configuration. |
| Busy state | Standalone Kimi is unknown pending a live-verified semantic source, preferring Wire's `prompt` lifetime then documented hooks including `Interrupt`; Kimi behind Pi uses Pi lifecycle, and the moon-phase spinner is never a state source. |
| Exit command | `/exit`. |
| Interrupt | Single Escape, which prints `Interrupted by user`. |
| Skill invocation | `/<skill>`, for example `/no-mistakes`; Firstmate skills are discovered. |
| Autonomy | `--auto`; `-y` and `--yolo` are weaker and are not used. |
| Trust dialog | Kimi 0.42.0 shows a one-time `Trust this folder?` selector for an unseen root before the welcome banner; Enter selects `Trust this folder`, the decision persists per root under `~/.kimi-code/workspace-trust/`, and `fm-spawn` has no Kimi trust automation, so an untrusted root times out at readiness. |
| Slash submission | One logical submit, with no popup swallow or settle hazard; the backend owns whether text plus submit is atomic. |
| Environment marker | None; identity comes from process ancestry command name `kimi`, which `../../../bin/fm-harness.sh` keeps a retained foreign marker from overriding. |
| Composer | Bordered box with a bare `>` prompt glyph and no observed ghost or placeholder text; Kimi 0.41.0 and 0.42.0 render `thinking` and `context` status rows immediately below the box. |
| Effort | No verified reasoning-effort flag; `references/common/model-and-effort.md` owns unsupported-value handling. |

## Readiness-gated start

`../../../bin/fm-spawn.sh` launches Kimi bare, waits for the composer box or `Welcome to Kimi Code!`, sends only `Read the brief at <absolute-path> and follow it exactly.`, and requires a cleared composer plus either the echoed `✨` submission or nonzero context before accepting delivery.
This launch-then-send shape is mandatory because Kimi rejects positional instructions as an unknown command.
The path must be absolute because the instructions live outside the task worktree and Kimi reads them there without `--add-dir`.

Sending before readiness was reproduced as a silent drop with zero exit status, an empty composer, `context: 0%`, no echoed user message, and a healthy-looking idle pane.
The startup input-readiness window is the established cause; the banner is not.
An early Enter can expand the composer to multiple content rows, leaving pointer text on the first row and the cursor on an empty later row.
The shared tmux reader therefore locates the complete bordered composer and treats real text on any content row as positive evidence that submission remains pending.
In the pinned Kimi 0.41.0 Herdr capture, a split text-plus-Enter path left the pointer pending in that boxed composer above Kimi's `thinking` and `context` footer.
Herdr now uses one atomic first submission, then retains Enter-only retries for a genuinely pending composer.
The shared reader treats that structured footer as furniture only after a bordered box, so real text remains `pending`, an empty box reads `empty`, and a left-bar or nonmatching footer remains `unknown`.
No rendering signal proves Kimi will accept input during this window, so delivery retries Enter through the shared submit core and retains the postcondition verification rather than relaxing readiness.
The default three-attempt submit budget spends its atomic attempt and any Enter retries within about two seconds, while the following delivery wait only observes; if a future failure leaves the pointer pending after that budget, raise `FM_KIMI_SUBMIT_RETRIES` rather than broadening the classifier.
The footer proof deliberately requires the lowercase `thinking` label; every configured model observed on Kimi 0.42.0 was `always_thinking`, so a future footer without that label falls back to `unknown`.

Observed spinner captures had optional leading whitespace, a moon-phase glyph, whitespace around `·`, and rotating tip text, including during tool execution.
The delivery-only matcher requires the observed whitespace, deliberately excludes the unobserved zero-whitespace form, and does not require trailing tip text.
Kimi's footer tip can show `ctrl+c: cancel` while idle, and its idle bar can contain lowercase `thinking` as an effort label.
Neither is a busy-state source.
The delivery-only spinner match covers the full moon-phase glyph set but remains locale- and emoji-font-sensitive because Kimi exposes no stable ASCII busy token.

## Crew and secondmate-primary turn-end hook

Kimi secondmates are inside the primary turn-end guard scope through a private entry in the global hook registry, while Kimi crew records retain the passive wake path.
The hook and shared guard are proven to return exit 2 plus a reason for a blind secondmate Stop, but a running Kimi honoring that result as a blocked Stop and sending `stop_hook_active=true` on its retry have not yet passed the live verification guard.
`../../../docs/turnend-guard.md` owns that global hook surface, the exact evidence boundary, and the refresh command.

`../../../bin/fm-spawn.sh` installs one marker-delimited Firstmate entry in `$HOME/.kimi-code/config.toml`, one guarded hook script, and one private token registry under `$HOME/.kimi-code/fm-turn-end.d/`.
Each Kimi worker worktree receives a gitignored `.fm-kimi-turnend` pointer.
For crew records, the global hook touches `state/<id>.turn-ended` only when the Stop payload's `cwd`, pointer, and registry entry all agree, then stays silent and exits 0.
For secondmate-primary records, it runs that marked home's tracked `bin/fm-turnend-guard.sh` and preserves the guard result for Kimi to interpret.
A guarded silent hook cannot be verified from absence of effect, so prove invocation with an unguarded probe before concluding it did not fire.
The guarded turn-end signal remains a wake notification.
Standalone Kimi has no busy-state source until one is live-verified.
