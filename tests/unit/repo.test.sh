#!/usr/bin/env bash
# Repository hygiene checks.

# Scripts are run as ./scripts/x.sh on Linux: git must store them as executable (100755).
# scripts/lib/*.sh is only sourced and stays 100644.
test_scripts_are_executable_in_git() {
  local f mode bad=""
  for f in "$ROOT"/scripts/*.sh "$ROOT"/tests/unit/run.sh; do
    f="${f#"$ROOT"/}"
    mode="$(git -C "$ROOT" ls-files -s -- "$f" | awk '{print $1}')"
    [[ "$mode" == 100755 ]] || bad+=" $f($mode)"
  done
  [[ -z "$bad" ]] || fail_test "not executable in git:$bad"
}
