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
    opam exec -- dune build @doc

lint-fmt:
    opam exec -- dune build @fmt

lint-opam:
    opam exec -- opam-dune-lint

lint: lint-doc lint-fmt lint-opam

# CC-specific commands

cc-post-write:
    echo '=== All checks ===' && just 2>&1 | head -30

cc-pre-write:
    echo 'REMINDER: If writing an implementation file, confirm its test file exists and is failing first (Article III).'

cc-checkpoint:
    echo '=== Session checkpoint ===' && git diff --stat HEAD 2>/dev/null && echo '' && echo 'Test status:' && just test 2>&1 | tail -5

cc-notify:
    osascript -e 'display notification "olog: Claude needs input" with title "Claude Code"' 2>/dev/null || echo '[Claude needs input]'
