#!/usr/bin/env bash
# Minimal bash test runner: sources each tests/unit/*.test.sh and runs its test_* functions.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export ROOT
export V="$ROOT/scripts/validate.sh"
export F="$ROOT/tests/fixtures"

assert_eq() { [[ "$1" == "$2" ]] || fail_test "$3: expected [$1] got [$2]"; }
assert_rc() {
  local expected=$1 rc=0
  shift
  "$@" >/dev/null 2>&1 || rc=$?
  [[ "$rc" == "$expected" ]] || fail_test "rc of '$*': expected $expected got $rc"
}
fail_test() { echo "    x $*"; : > "$TMP/.failed"; }
skip_test() { echo "    ~ skip: $*"; : > "$TMP/.skipped"; }

total_pass=0 total_fail=0 total_skip=0
results="$(mktemp)"

for file in "$ROOT"/tests/unit/*.test.sh; do
  echo "== $(basename "$file")"
  (
    # shellcheck source=/dev/null
    source "$file"
    for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
      TMP="$(mktemp -d)"
      export TMP
      ( "$t" ) || : > "$TMP/.failed"
      if [[ -e "$TMP/.failed" ]]; then
        echo "  FAIL $t"; echo fail >> "$results"
      elif [[ -e "$TMP/.skipped" ]]; then
        echo "  SKIP $t"; echo skip >> "$results"
      else
        echo "  ok   $t"; echo pass >> "$results"
      fi
      rm -rf "$TMP"
    done
  )
done

total_pass=$(grep -c '^pass$' "$results" || true)
total_fail=$(grep -c '^fail$' "$results" || true)
total_skip=$(grep -c '^skip$' "$results" || true)
rm -f "$results"
echo "-- unit: PASS $total_pass / FAIL $total_fail / SKIP $total_skip"
[[ "$total_fail" -eq 0 ]]
