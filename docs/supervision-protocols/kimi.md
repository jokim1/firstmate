Mode: Kimi foreground checkpoint with a registered Stop backstop.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Source `__FM_X_MODE_ENV__` first when Relay is active.
3. First cycle: run one foreground watcher checkpoint with `bin/fm-watch-checkpoint.sh --seconds "${FM_CODEX_WATCH_CHECKPOINT:-180}"`.
4. Ordinary wake: if the command prints `signal:`, `stale:`, `check:`, `heartbeat`, or `refill:`, drain queued wakes, handle that wake, then start the next checkpoint.
5. If the command prints `checkpoint:` or exits 124 with no wake, drain queued wakes anyway, process any queued user message now visible to Kimi, then start the next checkpoint.
6. Never use shell `&` for Firstmate watcher supervision.
7. Do not run `bin/fm-watch-arm.sh` as Kimi's normal supervision command.
8. Failure or missing cycle only: drain queued wakes, inspect the failure, then start a fresh foreground checkpoint.

Kimi cannot reason while a foreground tool call is running.
The bounded checkpoint returns control regularly so user messages and queued wakes can be handled without relying on an unverified background-task wake.

A Kimi secondmate launched by `bin/fm-spawn.sh` also receives a private global Stop-hook registry entry for its own home.
At a blind Stop with supervision still needed, that entry is proven to run `bin/fm-turnend-guard.sh` and return its exit 2 plus stderr reason to Kimi.
The protocol assumes Kimi interprets that result as one correction turn and sends `stop_hook_active=true` on the retry, matching the Claude-compatible hook model and the payload shape observed on Kimi 0.29.1.
That host behavior has not yet been verified against a running Kimi, so `FM_KIMI_LIVE_E2E=1 tests/fm-kimi-primary-live-e2e.test.sh` is the required upgrade guard and fails with the installed Kimi version when either premise is false.
When Kimi supplies the expected retry field, the shared guard allows that stop and bounds the backstop to one correction.
