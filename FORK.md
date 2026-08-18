# This fork

This repository is a fork of [kunchenguid/firstmate](https://github.com/kunchenguid/firstmate).
`origin` is [jokim1/firstmate](https://github.com/jokim1/firstmate).
The upstream remote is `upstream` and points at kunchenguid/firstmate for fetch only.

Day-to-day agent work, agent instructions, and the always-loaded contract live in [AGENTS.md](AGENTS.md).
This file is only the fork overlay and remote boundary.

## Overlay model

The default branch is `lila-main`.
It is an overlay: current upstream `main` plus a small curated stack of patches.
Each approved fork change lands as one squash commit on that stack.
The stack is periodically rebased onto current upstream `main`.

Force-push is expected and authorized **only** for `lila-main` on the jokim1 fork.
Never force-push any other branch.
Never force-push to upstream.

## Hard boundary: origin only

All pushes, pull requests, and merges target the origin fork (`jokim1/firstmate`) only.

Anything that writes to kunchenguid/firstmate - PR, push, merge, comment, issue, or cleanup of artifacts there - happens only on the captain's explicit per-item instruction.
Without that word, all upstream writes are forbidden.

Local clones enforce the push half of this boundary:
the `upstream` and `sanchith` remotes have push URLs disabled, so any push there fails loudly.

## Reconciling upstream vs ours

New upstream work arrives by rebasing the overlay stack onto upstream `main`.
The owner of that rebase is the operator-private script `data/patch-queue/rebase-lila-main.sh` in the operator's private home (not this repo).
Do not reimplement or invent a second rebase path.

Each patch carries a retire-when condition and is dropped once upstream covers it.
Conflicts are never auto-resolved: on conflict the rebase stops, and a human or supervised agent resolves deliberately.

## What a rebase means for checkouts

A rebase rewrites overlay commit IDs.
Previously updated checkouts cannot fast-forward afterward; update tooling will report them skipped as diverged.
That outcome is expected.

The fix is a deliberate reset to the new `lila-main` tip during a quiet window.
Do not merge to "catch up".
Do not force-push anywhere except the authorized `lila-main` origin path above.
