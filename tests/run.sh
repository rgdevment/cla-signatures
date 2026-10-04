#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154,SC2329
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
workflow="$here/../.github/workflows/cla.yml"

# The script lives in the workflow, so a reusable workflow needs no checkout of this repository.
script=$(awk '
  /^      - id: cla$/ { found = 1 }
  found && /^        run: \|$/ { body = 1; next }
  body && /^          / { sub(/^          /, ""); print; next }
  body && /^$/ { print; next }
  body { exit }
' "$workflow")
[ -n "$script" ] || { echo "x  the script could not be read out of the workflow"; exit 1; }

CLA_LIBRARY=1
# bash 3.2 on macOS cannot source a process substitution.
lib=$(mktemp)
event=$(mktemp)
trap 'rm -f "$lib" "$event"' EXIT
printf '%s\n' "$script" > "$lib"
# shellcheck disable=SC1090
source "$lib"
set +e

failed=0
same() {
  if [ "$2" == "$3" ]; then
    printf 'ok %s\n' "$1"
  else
    printf 'x  %s\n--- wanted\n%s\n--- got\n%s\n' "$1" "$3" "$2"
    failed=1
  fi
}

commits='[
  {"commit": {"authors": {"nodes": [
    {"email": "r@example.com", "name": "R", "user": {"databaseId": 1, "login": "rgdevment"}},
    {"email": "private@example.com", "name": "New Person", "user": {"databaseId": 99, "login": "newbie"}},
    {"email": "bot@tool.example", "name": "Some Tool", "user": null}]}}},
  {"commit": {"authors": {"nodes": [
    {"email": "Unlinked@Example.com", "name": "Unlinked", "user": null}]}}},
  {"commit": {"authors": {"nodes": [
    {"email": "r@example.com", "name": "R", "user": {"databaseId": 1, "login": "rgdevment"}},
    {"email": "old@example.com", "name": "Old", "user": {"databaseId": 42, "login": "olduser"}}]}}}
]'

people_seen=$(people <<< "$commits")
same "every author and co-author, once" "$people_seen" "$(printf '%s\n' \
  $'account\t1\trgdevment' \
  $'account\t42\tolduser' \
  $'account\t99\tnewbie' \
  $'email\tbot@tool.example\tSome Tool' \
  $'email\tunlinked@example.com\tUnlinked' | sort -u -t $'\t' -k1,2)"

GITHUB_EVENT_PATH=$event
printf '{"pull_request": {"number": 5, "user": {"id": 7, "login": "alice"}}}' > "$event"
same "whoever opened the pull request is named" "$(opener)" $'account\t7\talice'
printf '{"issue": {"number": 5, "user": {"id": 7, "login": "alice"}}, "comment": {}}' > "$event"
same "and named the same from a comment" "$(opener)" $'account\t7\talice'

ALLOWLIST='rgdevment, dependabot[bot] ,ci-*'
allowed rgdevment && a=yes || a=no
same "an exact login is allowed" "$a" yes
allowed 'dependabot[bot]' && a=yes || a=no
same "brackets are part of the name" "$a" yes
allowed dependabotb && a=yes || a=no
same "brackets are not a character class" "$a" no
allowed ci-runner && a=yes || a=no
same "a star matches the rest" "$a" yes
allowed rgdevment2 && a=yes || a=no
same "a prefix is not the name" "$a" no

signatures='{"signedContributors": [{"name": "olduser", "id": 42}]}'
everyone=$({ printf '%s\n' "$people_seen"; opener; } | sort -u -t $'\t' -k1,2)
same "who still owes a signature" "$(unsigned "$signatures" <<< "$everyone")" "$(printf '%s\n' \
  $'account\t7\talice' \
  $'account\t99\tnewbie' \
  $'email\tbot@tool.example\tSome Tool' \
  $'email\tunlinked@example.com\tUnlinked')"
same "nobody owes anything on an empty pull request" "$(unsigned "$signatures" <<< "")" ""

# What the Contents API hands back: base64 broken every 60 characters.
long=$(jq -n '{signedContributors: [range(5) | {name: "someone\(.)", id: ., comment_id: 1, created_at: "x", repoId: 1, pullRequestNo: 1}]}')
wrapped=$(printf '%s\n' "$long" | base64 | tr -d '\n' | fold -w 60)
file=$(jq -n --arg content "$wrapped" '{content: $content, sha: "abc"}')
same "a wrapped file decodes" "$(decoded <<< "$file" | jq -c '.signedContributors | length')" 5

same "the phrase signs" "$(printf 'I have read the CLA Document and I hereby sign the CLA' | plain)" \
  "i have read the cla document and i hereby sign the cla"
same "case, spacing and a full stop do not" \
  "$(printf '  I have read the CLA document  and I hereby sign the CLA.\n' | plain)" \
  "i have read the cla document and i hereby sign the cla"
same "a different sentence does not sign" "$(printf 'I have read the CLA' | plain)" "i have read the cla"

NOT_SIGNED="Sign it." SIGN_PHRASE="I sign" DOCUMENT_URL="https://example.com/CLA.md"
said=$(worded "$(unsigned "$signatures" <<< "$everyone")")
same "the comment carries its marker first" "$(head -1 <<< "$said")" "$marker"
same "the comment names an account by mention" "$(grep -c '^- @alice$' <<< "$said")" 1
same "an address is never mentioned as a login" "$(grep -c '@bot@tool' <<< "$said")" 0
same "the phrase is quoted" "$(grep -c '^> I sign$' <<< "$said")" 1

exit $failed
