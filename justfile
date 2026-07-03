default: build test fmt lint

build:
    opam exec -- dune build

test:
    opam exec -- dune runtest

test-single-idx SUITE NAME_REGEX CASE:
    opam exec -- dune exec test/test_{{SUITE}}.exe -- test "{{NAME_REGEX}}" "{{CASE}}"

test-list SUITE:
    opam exec -- dune exec test/test_{{SUITE}}.exe -- list

fmt:
    opam exec -- dune fmt

lint-doc:
    #!/usr/bin/env bash
    set -euo pipefail
    out=$(opam exec -- dune build @doc --force 2>&1)
    printf '%s\n' "$out"
    if printf '%s\n' "$out" | grep -q 'Warning:'; then
        echo 'lint-doc FAIL: odoc warnings present (CI treats these as errors)' >&2
        exit 1
    fi

lint-fmt:
    opam exec -- dune build @fmt

lint-opam:
    opam exec -- opam-dune-lint

lint: lint-doc lint-fmt lint-opam

# CC-specific commands

# leave it light as it might otherwise slow down the workflow
cc-post-write:

cc-pre-write:
    echo 'REMINDER: If writing an implementation file, confirm its test file exists and is failing first (Article III).'

cc-checkpoint:
    echo '=== Session checkpoint ===' && git --no-pager diff --stat HEAD 2>/dev/null && echo '' && echo 'Build & test status:' && just 2>&1 | tail -10

cc-notify:
    osascript -e 'display notification "olog: Claude needs input" with title "Claude Code"' 2>/dev/null || echo '[Claude needs input]'
