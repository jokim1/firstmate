#!/usr/bin/env bash
# Live-drive bin/fm-test-run.sh wall-guard + aggregate imbalance, and the CI
# workflow argv pin, without touching the operator fleet or mutating the repo.
set -u
set -o pipefail

ROOT="/Users/josephkim/.no-mistakes/worktrees/556cf8b265ba/01M3G062ZN067CCCRX6BS4WESP"
EVIDENCE="/Users/josephkim/.no-mistakes/evidence/01M3G062ZN067CCCRX6BS4WESP"
RUNNER="$ROOT/bin/fm-test-run.sh"
CI_YML="$ROOT/.github/workflows/ci.yml"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-wall-guard-live.XXXXXX")
SUMMARY="$EVIDENCE/live-scenarios.jsonl"
trap 'rm -rf "$TMP"' EXIT

cd "$ROOT" || exit 1
: >"$SUMMARY"

record() {
  local name=$1 result=$2 detail=$3
  printf '%s\n' "$detail" >"$EVIDENCE/${name}.txt"
  printf '{"name":"%s","result":"%s","file":"%s"}\n' "$name" "$result" "$EVIDENCE/${name}.txt" >>"$SUMMARY"
  printf 'SCENARIO %s -> %s\n' "$name" "$result"
}

cat >"$TMP/fast.test.sh" <<'SH'
#!/usr/bin/env bash
echo "ok - wall-guard fast fixture"
exit 0
SH
cat >"$TMP/slow.test.sh" <<'SH'
#!/usr/bin/env bash
sleep 1
echo "ok - wall-guard slow fixture"
exit 0
SH
chmod +x "$TMP/fast.test.sh" "$TMP/slow.test.sh"

unset FM_TASK_ID || true

# --- 1. Under the CI 18-minute bound, a green script passes and reports budget
set +e
"$RUNNER" --max-wall-ms 1080000 --json "$TMP/under.json" "$TMP/fast.test.sh" \
  >"$TMP/under.out" 2>"$TMP/under.err"
rc=$?
set -e
{
  echo "exit=$rc"
  echo "----- stdout -----"
  cat "$TMP/under.out"
  echo "----- stderr -----"
  cat "$TMP/under.err"
  echo "----- json -----"
  cat "$TMP/under.json" 2>/dev/null || true
} >"$EVIDENCE/under-budget.txt"
if [ "$rc" -eq 0 ] \
  && grep -Eq '^FM_TEST_BUDGET max_wall_ms=1080000 duration_ms=[0-9]+$' "$TMP/under.out" \
  && grep -Eq '^FM_TEST_SUMMARY total=1 failed=0' "$TMP/under.out"; then
  budget_ms=$(awk '/^FM_TEST_BUDGET / { for (i=1;i<=NF;i++) if ($i ~ /^duration_ms=/) { sub(/^duration_ms=/, "", $i); print $i } }' "$TMP/under.out")
  if [ "$budget_ms" -le 1080000 ]; then
    record "under-ci-bound" "pass" "$(cat "$EVIDENCE/under-budget.txt")"
  else
    record "under-ci-bound" "fail" "duration $budget_ms exceeded bound unexpectedly
$(cat "$EVIDENCE/under-budget.txt")"
  fi
else
  record "under-ci-bound" "fail" "$(cat "$EVIDENCE/under-budget.txt")"
fi

# --- 2. Over-budget green run fails closed (the drift the CI pin exists for)
set +e
"$RUNNER" --max-wall-ms 50 --json "$TMP/over.json" "$TMP/slow.test.sh" \
  >"$TMP/over.out" 2>"$TMP/over.err"
rc=$?
set -e
{
  echo "exit=$rc"
  echo "----- stdout -----"
  cat "$TMP/over.out"
  echo "----- stderr -----"
  cat "$TMP/over.err"
  echo "----- json still written -----"
  cat "$TMP/over.json" 2>/dev/null || echo "NO JSON"
} >"$EVIDENCE/over-budget.txt"
if [ "$rc" -eq 1 ] \
  && grep -Eq '^FM_TEST_SUMMARY total=1 failed=0' "$TMP/over.out" \
  && grep -Eq '^FM_TEST_BUDGET max_wall_ms=50 duration_ms=[0-9]+$' "$TMP/over.out" \
  && grep -F 'wall-clock budget exceeded' "$TMP/over.out" \
  && [ -s "$TMP/over.json" ]; then
  record "over-budget-fails-closed" "pass" "$(cat "$EVIDENCE/over-budget.txt")"
else
  record "over-budget-fails-closed" "fail" "$(cat "$EVIDENCE/over-budget.txt")"
fi

# --- 3. CI-shaped flags: extract argv from the real workflow and invoke it
ruby -ryaml -rshellwords - "$CI_YML" "$TMP" <<'RUBY' >"$TMP/ci-extract.txt"
doc = YAML.load_file(ARGV[0])
max_wall = doc.fetch("env").fetch("FM_TEST_PORTABLE_PARALLEL_MAX_WALL_MS")
raise "unexpected env bound #{max_wall.inspect}" unless max_wall == 1080000
File.write(File.join(ARGV[1], "workflow-max-wall"), max_wall.to_s)

drop_comment = lambda do |line|
  line.gsub(/('[^']*'|"[^"]*")|#.*/) { |m| m.start_with?("#") ? "" : m }
end
fm_test_run_argv = lambda do |run|
  commands = []
  run.to_s.gsub(/\\\n/, " ").each_line do |line|
    stripped = drop_comment.call(line).strip
    next if stripped.empty?
    argv = Shellwords.split(stripped)
    commands << argv if argv[0] == "bin/fm-test-run.sh"
  end
  raise "expected one bin/fm-test-run.sh, found #{commands.length}" unless commands.length == 1
  commands.fetch(0)
end
max_wall_operands = lambda do |argv|
  operands = []
  i = 1
  while i < argv.length
    arg = argv.fetch(i)
    if arg == "--max-wall-ms"
      operands << argv[i + 1]
      i += 2
    elsif arg.start_with?("--max-wall-ms=")
      operands << arg.delete_prefix("--max-wall-ms=")
      i += 1
    else
      i += 1
    end
  end
  operands
end
%w[tests-portable-parallel-1 tests-portable-parallel-2].each do |job_name|
  step = doc.fetch("jobs").fetch(job_name).fetch("steps")
              .find { |s| s["name"].to_s.start_with?("Run portable parallel shard") }
  argv = fm_test_run_argv.call(step.fetch("run"))
  ops = max_wall_operands.call(argv)
  raise "#{job_name} operands=#{ops.inspect}" unless ops == ["$FM_TEST_PORTABLE_PARALLEL_MAX_WALL_MS"]
  File.write(File.join(ARGV[1], "#{job_name}.argv"), argv.shelljoin + "\n")
  puts "#{job_name}\t#{argv.shelljoin}"
end
RUBY
extract_rc=$?
{
  echo "extract_exit=$extract_rc"
  cat "$TMP/ci-extract.txt"
  echo "----- parallel-1 argv -----"
  cat "$TMP/tests-portable-parallel-1.argv" 2>/dev/null || true
  echo "----- parallel-2 argv -----"
  cat "$TMP/tests-portable-parallel-2.argv" 2>/dev/null || true
} >"$EVIDENCE/ci-argv-extract.txt"

# Drive the extracted wall-guard the way CI expands the env, against a tiny
# script (full --lane portable-parallel-* is a 10+ minute hosted-runner shard).
# Also prove --lane + --max-wall-ms 1080000 is accepted via --list.
set +e
FM_TEST_PORTABLE_PARALLEL_MAX_WALL_MS=$(cat "$TMP/workflow-max-wall")
"$RUNNER" --lane portable-parallel-1 \
  --fail-on-gate-skip 'Pi extension typecheck prerequisite not found' \
  --max-wall-ms "$FM_TEST_PORTABLE_PARALLEL_MAX_WALL_MS" \
  --list >"$TMP/ci-list.out" 2>"$TMP/ci-list.err"
list_rc=$?
"$RUNNER" --fail-on-gate-skip 'Pi extension typecheck prerequisite not found' \
  --max-wall-ms "$FM_TEST_PORTABLE_PARALLEL_MAX_WALL_MS" \
  --json "$TMP/ci-shaped.json" \
  "$TMP/fast.test.sh" >"$TMP/ci-shaped.out" 2>"$TMP/ci-shaped.err"
shaped_rc=$?
set -e
{
  echo "list_exit=$list_rc shaped_exit=$shaped_rc env=$FM_TEST_PORTABLE_PARALLEL_MAX_WALL_MS"
  echo "----- --lane --list stdout (first 20) -----"
  head -n 20 "$TMP/ci-list.out"
  echo "... count=$(wc -l <"$TMP/ci-list.out" | tr -d ' ')"
  echo "----- --lane --list stderr -----"
  cat "$TMP/ci-list.err"
  echo "----- CI-shaped tiny run -----"
  cat "$TMP/ci-shaped.out"
  echo "----- CI-shaped stderr -----"
  cat "$TMP/ci-shaped.err"
  echo "----- extract -----"
  cat "$EVIDENCE/ci-argv-extract.txt"
} >"$EVIDENCE/ci-wired-flags.txt"
if [ "$extract_rc" -eq 0 ] && [ "$list_rc" -eq 0 ] && [ "$shaped_rc" -eq 0 ] \
  && grep -Eq '^FM_TEST_BUDGET max_wall_ms=1080000 duration_ms=[0-9]+$' "$TMP/ci-shaped.out" \
  && [ "$(wc -l <"$TMP/ci-list.out" | tr -d ' ')" -gt 5 ]; then
  record "ci-wired-wall-guard" "pass" "$(cat "$EVIDENCE/ci-wired-flags.txt")"
else
  record "ci-wired-wall-guard" "fail" "$(cat "$EVIDENCE/ci-wired-flags.txt")"
fi

# --- 4. Aggregate reports parallel imbalance and does not fail
python3 - "$TMP" <<'PY'
import json, pathlib, shutil, sys
tmp = pathlib.Path(sys.argv[1])
under = json.loads((tmp / "ci-shaped.json").read_text())
over = json.loads((tmp / "over.json").read_text())
p1 = dict(under)
p1["selection"] = "lane=portable-parallel-1;fail-on-gate-skip=Pi extension typecheck prerequisite not found"
p1["summary"] = dict(p1.get("summary") or {})
p1["summary"]["duration_ms"] = 1000
p1["summary"]["failed"] = 0
(tmp / "p1.json").write_text(json.dumps(p1, indent=2) + "\n")
p2 = dict(over)
p2["selection"] = "lane=portable-parallel-2"
p2["summary"] = dict(p2.get("summary") or {})
p2["summary"]["duration_ms"] = 2000
p2["summary"]["failed"] = 0
(tmp / "p2.json").write_text(json.dumps(p2, indent=2) + "\n")
serial = dict(under)
serial["selection"] = "lane=portable-serial-1of9"
serial["summary"] = dict(serial.get("summary") or {})
serial["summary"]["duration_ms"] = 9000
serial["summary"]["failed"] = 0
(tmp / "serial.json").write_text(json.dumps(serial, indent=2) + "\n")
huge1 = dict(p1)
huge1["summary"] = dict(huge1["summary"])
huge1["summary"]["duration_ms"] = 700000
(tmp / "huge1.json").write_text(json.dumps(huge1, indent=2) + "\n")
huge2 = dict(p2)
huge2["summary"] = dict(huge2["summary"])
huge2["summary"]["duration_ms"] = 400000
(tmp / "huge2.json").write_text(json.dumps(huge2, indent=2) + "\n")
PY

set +e
agg_out=$("$RUNNER" --aggregate-json "$TMP/agg.json" "$TMP/p1.json" "$TMP/p2.json" "$TMP/serial.json")
agg_rc=$?
set -e
{
  echo "exit=$agg_rc"
  echo "stdout=$agg_out"
  echo "----- aggregate json -----"
  cat "$TMP/agg.json"
} >"$EVIDENCE/aggregate-imbalance.txt"
if [ "$agg_rc" -eq 0 ] \
  && printf '%s\n' "$agg_out" | grep -F 'portable_parallel_1_ms=1000 portable_parallel_2_ms=2000 imbalance_ms=1000' \
  && printf '%s\n' "$agg_out" | grep -F 'FM_TEST_AGGREGATE lanes=3' \
  && ! printf '%s\n' "$agg_out" | grep -F 'portable_serial'; then
  record "aggregate-reports-imbalance" "pass" "$(cat "$EVIDENCE/aggregate-imbalance.txt")"
else
  record "aggregate-reports-imbalance" "fail" "$(cat "$EVIDENCE/aggregate-imbalance.txt")"
fi

# --- 5. Adversarial: one parallel lane only -> no imbalance fields, still exit 0
set +e
one_out=$("$RUNNER" --aggregate-json "$TMP/one.json" "$TMP/p1.json" "$TMP/serial.json")
one_rc=$?
set -e
{
  echo "exit=$one_rc"
  echo "stdout=$one_out"
} >"$EVIDENCE/aggregate-one-lane.txt"
if [ "$one_rc" -eq 0 ] \
  && printf '%s\n' "$one_out" | grep -F 'FM_TEST_AGGREGATE lanes=2' \
  && ! printf '%s\n' "$one_out" | grep -E 'imbalance_ms=|portable_parallel_1_ms='; then
  record "aggregate-one-lane-no-imbalance" "pass" "$(cat "$EVIDENCE/aggregate-one-lane.txt")"
else
  record "aggregate-one-lane-no-imbalance" "fail" "$(cat "$EVIDENCE/aggregate-one-lane.txt")"
fi

# --- 6. Adversarial: huge imbalance with all tests passing still exits 0
set +e
huge_out=$("$RUNNER" --aggregate-json "$TMP/huge.json" "$TMP/huge1.json" "$TMP/huge2.json")
huge_rc=$?
set -e
{
  echo "exit=$huge_rc"
  echo "stdout=$huge_out"
} >"$EVIDENCE/aggregate-huge-imbalance.txt"
if [ "$huge_rc" -eq 0 ] \
  && printf '%s\n' "$huge_out" | grep -F 'imbalance_ms=300000' \
  && printf '%s\n' "$huge_out" | grep -F 'failed=0'; then
  record "aggregate-huge-imbalance-does-not-fail" "pass" "$(cat "$EVIDENCE/aggregate-huge-imbalance.txt")"
else
  record "aggregate-huge-imbalance-does-not-fail" "fail" "$(cat "$EVIDENCE/aggregate-huge-imbalance.txt")"
fi

# --- 7. Adversarial: commented-out / duplicated wall guard fails the argv pin
python3 - "$CI_YML" "$TMP" <<'PY'
from pathlib import Path
import sys
src = Path(sys.argv[1]).read_text()
tmp = Path(sys.argv[2])
commented = src.replace(
    '            --max-wall-ms "$FM_TEST_PORTABLE_PARALLEL_MAX_WALL_MS" \\\n',
    '            # --max-wall-ms "$FM_TEST_PORTABLE_PARALLEL_MAX_WALL_MS" \\\n',
    1,
)
(tmp / "ci-commented.yml").write_text(commented)
dup = src.replace(
    '            --max-wall-ms "$FM_TEST_PORTABLE_PARALLEL_MAX_WALL_MS" \\\n            --json "$RUNNER_TEMP/fm-test/fm-test-timing-portable-parallel-1.json"\n',
    '            --max-wall-ms "$FM_TEST_PORTABLE_PARALLEL_MAX_WALL_MS" \\\n            --max-wall-ms "$FM_TEST_PORTABLE_PARALLEL_MAX_WALL_MS" \\\n            --json "$RUNNER_TEMP/fm-test/fm-test-timing-portable-parallel-1.json"\n',
    1,
)
(tmp / "ci-dup.yml").write_text(dup)
PY

check_pin() {
  local yml=$1
  ruby -ryaml -rshellwords - "$yml" <<'RUBY'
doc = YAML.load_file(ARGV[0])
max_wall = doc.fetch("env").fetch("FM_TEST_PORTABLE_PARALLEL_MAX_WALL_MS")
expected_max_wall = 1080000
raise "bound" unless max_wall == expected_max_wall
drop_comment = lambda do |line|
  line.gsub(/('[^']*'|"[^"]*")|#.*/) { |m| m.start_with?("#") ? "" : m }
end
fm_test_run_argv = lambda do |run|
  commands = []
  run.to_s.gsub(/\\\n/, " ").each_line do |line|
    stripped = drop_comment.call(line).strip
    next if stripped.empty?
    argv = Shellwords.split(stripped)
    commands << argv if argv[0] == "bin/fm-test-run.sh"
  end
  raise "run step must invoke bin/fm-test-run.sh once, found #{commands.length}" unless commands.length == 1
  commands.fetch(0)
end
max_wall_operands = lambda do |argv|
  operands = []
  i = 1
  while i < argv.length
    arg = argv.fetch(i)
    if arg == "--max-wall-ms"
      operands << argv[i + 1]
      i += 2
    elsif arg.start_with?("--max-wall-ms=")
      operands << arg.delete_prefix("--max-wall-ms=")
      i += 1
    else
      i += 1
    end
  end
  operands
end
%w[tests-portable-parallel-1 tests-portable-parallel-2].each do |job_name|
  step = doc.fetch("jobs").fetch(job_name).fetch("steps")
              .find { |s| s["name"].to_s.start_with?("Run portable parallel shard") }
  raise "#{job_name} has no portable parallel run step" unless step
  operands = max_wall_operands.call(fm_test_run_argv.call(step.fetch("run")))
  raise "#{job_name} must pass --max-wall-ms exactly once wired to the env value, got #{operands.inspect}" \
    unless operands == ["$FM_TEST_PORTABLE_PARALLEL_MAX_WALL_MS"]
end
RUBY
}

set +e
check_pin "$CI_YML" >"$TMP/pin-real.out" 2>"$TMP/pin-real.err"
pin_real=$?
check_pin "$TMP/ci-commented.yml" >"$TMP/pin-comment.out" 2>"$TMP/pin-comment.err"
pin_comment=$?
check_pin "$TMP/ci-dup.yml" >"$TMP/pin-dup.out" 2>"$TMP/pin-dup.err"
pin_dup=$?
set -e
{
  echo "real_exit=$pin_real (want 0)"
  cat "$TMP/pin-real.err"
  echo "commented_exit=$pin_comment (want non-zero)"
  cat "$TMP/pin-comment.err"
  echo "dup_exit=$pin_dup (want non-zero)"
  cat "$TMP/pin-dup.err"
} >"$EVIDENCE/argv-pin-adversarial.txt"
if [ "$pin_real" -eq 0 ] && [ "$pin_comment" -ne 0 ] && [ "$pin_dup" -ne 0 ]; then
  record "argv-pin-rejects-comment-and-dup" "pass" "$(cat "$EVIDENCE/argv-pin-adversarial.txt")"
else
  record "argv-pin-rejects-comment-and-dup" "fail" "$(cat "$EVIDENCE/argv-pin-adversarial.txt")"
fi

echo "----- live scenario index -----"
cat "$SUMMARY"
echo "TMP was $TMP (cleaned on exit)"
