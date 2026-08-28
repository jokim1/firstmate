# fm-mainred-fix: all three test lanes green

Scope: exactly three test files, empty `bin/` diff (verified via
`git diff 7b1be83..4a48112 -- bin/` returning nothing).

## fm-wake-queue.test.sh — five consecutive runs (intent: five passing runs)

```
RUN 1: exit=0 passes=33 not_ok=0
RUN 2: exit=0 passes=33 not_ok=0
RUN 3: exit=0 passes=33 not_ok=0
RUN 4: exit=0 passes=33 not_ok=0
RUN 5: exit=0 passes=33 not_ok=0
```

The widened negative first-observation legs (stall threshold 60s, well above the
2s observation window) never publish a stall on row age alone.

## fm-backend-herdr-presentation-e2e.test.sh — real Herdr E2E

Ran against real herdr 0.8.0 (protocol 19), treehouse v2.3.0, jq, with a running
default Herdr session so the final tripwire could arm.

```
EXIT=0
passes=23
not_ok=0
```

Final assertions (the last lines through the default-session tripwire):

```
ok - real Herdr lab: multi-home exact-pane teardowns restore captain focus without workspace close authority
ok - real Herdr lab: missing, renamed, and duplicate tokens trigger zero destructive or adoptive calls, and live duplicate risk refuses launch
ok - real Herdr lab validation completed on Herdr 0.8.0 with the default-session tripwire intact
```

The `warning:` / `error:` lines interleaved above (no exact token match; quarantine
duplicate; refusing duplicate launch) are the asserted expected behaviors of the
missing/renamed/duplicate-token case, not failures — the following `ok -` line
confirms zero destructive calls and a refused duplicate launch. The ten
post-restart spawn_task calls are isolated in the separate RECOVERY_PROJECT_DIR
Treehouse project. No `fm-lab-*` session leaked and no temp dir remained after
the run.

## fm-public-followup.test.sh — expiry fixture

```
EXIT=0
passes=52
not_ok=0
```

Regression reproduced and fixed — see public-followup-expiry-fixture.md.
