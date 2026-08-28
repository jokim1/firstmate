# fm-public-followup expiry-fixture: regression reproduced and fixed

The durable fix replaces lapsed `2026-08-28T01:12:00Z` "not-yet-expired" fixture
timestamps with a far-future `2099-08-28T01:12:00Z` value. Today's date is
2026-08-28, so the old fixture had already lapsed, making serial shard 3
deterministically red.

## Reproduction (before the fix)

Current wall clock at test time:

```
Fri Aug 28 21:01:20 UTC 2026
```

A copy of the test with only the fixture reverted to the base `2026-08-28`
timestamps fails, because a fixture that is supposed to be not-yet-expired is
already ~20 hours in the past:

```
ok - CONTROL: the identical teardown REFUSES the moment a commitment is registered
fm-public-followup: followup_expires_at 2026-08-28T01:12:00Z is in the past: the thread
  can no longer be reached, so this loop cannot be closed publicly. This is a captain decision.
not ok - rechain failed:
```

Result: `EXIT=1`, 34 ok, 1 not ok.

## After the fix (current head, 2099 fixture)

```
EXIT=0
passes=52
not_ok=0
ok - expiry escalation is pinned by FMX_NOW_OVERRIDE
```

The explicitly-expired cases still assert expiry deterministically via
`FMX_NOW_OVERRIDE`, so both intended behaviors (not-yet-expired vs explicitly
expired) are preserved.
