---
name: credential-handoff
description: >-
Captain's standing procedure for taking a credential/secret from him without chat exposure and depositing it where its production consumer reads it.
Load before requesting, receiving, placing, or verifying any credential, token, or secret handover.
Covers the one-home rule and the envelope handoff mechanics.
user-invocable: false
metadata:
internal: true
---

# Credential handoff

Captain preference, offloaded here from the always-loaded `data/captain.md` so the detailed mechanics load only when a secret handover is actually in hand.

## The one-home rule (captain root-cause session 2026-08-23)

Every credential lives ONLY where its production consumer reads it - no stored agent-side copies.
Copies drift; a config referencing a credential is verified readable + valid at SETUP time, never discovered dead at use time.

## Envelope handoff (no chat exposure)

Never ask the captain to paste a secret into chat.

1. He copies the key, then in a plain terminal runs `pbpaste > ~/.secrets/<name>` (directory `700`, file `600`).
2. He says only the path in chat.
3. The worker deposits it into the one home that consumes it, verifies with a real call, then DELETES the envelope - keeping the envelope only on verification failure.

## Related (kept in always-loaded preferences)

- Credentials for headless work: narrowly scoped static token over per-agent OAuth; broad/admin-shaped returns the choice to the captain; env var, never a file.
- Lila Games identity: every writing call on a Lila repo needs the `jklila` work-account token - full rule in `data/captain-shared.md`.

## Kimi lane: `auth_required` is ambiguous (2026-09-11, corrected 2026-09-13)

A `quota-axi` row reading `auth_required` for kimi is AMBIGUOUS. Disambiguate before escalating, because one of the two causes needs nothing from the captain.

**First check `~/.kimi-code/credentials/kimi-code.json` for a `refresh_token`.**

- **`refresh_token` present: the login is healthy, do NOT escalate.** Kimi access tokens carry `expires_in: 900`, and `quota-axi` (0.1.31) reads `expires_at` without ever consulting `refresh_token`, so a perfectly good login reads as `auth_required` for most of every 15-minute gap between CLI invocations. Confirm by checking whether the mates on that lane are still completing work. The only real cost is that quota-aware lane management cannot measure kimi, so anything pinned to a kimi lane is exempt from quota-driven moves. Upstream: https://github.com/kunchenguid/quota-axi/issues/163; tracked locally as `fm-kimi-lane-telemetry-blind`.
- **`refresh_token` absent, or present but work is actually failing: the stored token was rejected.** Only the captain's `kimi login` fixes that; escalate it the same turn rather than routing dispatches around the lane - doing that starved the lane for a day.

Getting this backwards sends the captain to re-login a working account and then re-wrap the hook block for nothing (nearly done 2026-09-13).

That login rewrites `~/.kimi-code/config.toml` and strips the Firstmate hook markers. The installer now adopts the byte-identical marker-less `[[hooks]] Stop` block instead of refusing, so a re-login no longer breaks the next dispatch and there is nothing to repair for that case. Verification evidence: `data/fm-kimi-relogin-verify-2026-09-11/`.

The manual repair is only for the other case: install still refuses when an existing Stop block genuinely differs from what install would write, and the refusal names the differing line.

1. Back up `config.toml`.
2. Delete the differing marker-less `[[hooks]] Stop` block.
3. Run `bin/fm-kimi-turnend-hook.sh install`.
4. Spawn.

## Kimi lane: two spawn/run gotchas (2026-09-14)

**Folder trust blocks the first spawn into any new project root.** Kimi 0.42.0 shows a one-time `Trust this folder?` selector, `fm-spawn` has no automation for it, and an untrusted root simply times out at readiness with `kimi did not show a verified ready signal before brief delivery`. Answer it in the pane with Enter (`Trust this folder` is preselected); the decision persists per root under `~/.kimi-code/workspace-trust/`.

The recovery trap: the failed spawn still leaves the treehouse worktree LEASED. Re-spawning then takes a fresh slot, which is a different root, so it hits the same dialog and fails again. Verify the worktree is clean, return it with `treehouse return <worktree-path>`, then re-spawn into the now-trusted slot.

**A transient network failure at token refresh kills a running worker.** Kimi's access token lasts 15 minutes; when the refresh call cannot reach `auth.kimi.com` the session stops with `OAuth request ... Connect Timeout Error` and an empty composer, mid-task. Observed 2026-09-14 after ~40 minutes of good work. The work survives uncommitted in the worktree and the pane stays alive, so check the endpoint is reachable again (`curl -o /dev/null -w '%{http_code}' https://auth.kimi.com/api/oauth/token` answering 405 is healthy) and steer the worker to resume; a relaunch is not needed and would discard its context. Treat it as a real dispatch risk for long pipeline runs, not as a sign-in problem.
