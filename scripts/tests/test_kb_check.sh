#!/usr/bin/env bash
# kb-check: a seeded knowledge base is clean; a note without sources or a permalink, a
# credential (named by file, never by match) and a missing index all fail.
set -u
. "$(dirname "$0")/lib.sh"
sandbox
K="$WORK/knowledge"
printf '# Knowledge base\n' > "$K/index.md"; printf '# Using this knowledge base\n' > "$K/USAGE_GUIDE.md"
cat > "$K/release-process.md" <<'N'
---
title: Release process
updated: 2026-01-15
sources:
  - https://acme.slack.com/archives/C0123ABCD/p1736935200000100
---
# Release process

- Releases every second Wednesday.
N
kc() { run kb-check.sh; }
assert_eq 0 "$(kc | jq '.problems | length')" "a well-formed knowledge base is clean"
assert_eq 1 "$(kc | jq .notes)" "index, guide and sources are not counted as notes"

printf -- '---\ntitle: x\nupdated: 2026-01-15\n---\n# x\n' > "$K/no-sources.md"
assert_contains "no sources" "$(kc | jq -r '.problems[] | select(.path == "no-sources.md") | .problem')" "a note without sources: fails"
printf -- '# no front matter\n' > "$K/bare.md"
assert_contains "no front matter" "$(kc | jq -r '.problems[] | select(.path == "bare.md") | .problem')" "a note without front matter fails"
rm -f "$K/no-sources.md" "$K/bare.md"

# credential: assembled at runtime so this file holds no scanner-matching literal
printf -- '---\nupdated: 2026-01-15\nsources:\n  - https://acme.slack.com/archives/C0123ABCD/p1736935200000100\n---\ntoken xox%s-%s\n' b 1234567890-abcdefghij > "$K/leak.md"
out="$(kc)"
assert_contains "credential" "$(printf '%s' "$out" | jq -r '.problems[] | select(.path == "leak.md") | .problem')" "a credential fails, by file"
assert_not_contains "1234567890" "$out" "the match itself is never reported"
rm -f "$K/leak.md" "$K/index.md"
assert_eq fail "$(kc | jq -r '.problems[] | select(.path == "index.md") | .severity')" "a missing index fails"
exit $FAILURES
