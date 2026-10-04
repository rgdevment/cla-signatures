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
trap 'rm -f "$lib"' EXIT
printf '%s\n' "$script" > "$lib"
# shellcheck disable=SC1090
source "$lib"
set +e

gh() {
  case "$*" in
    "api users/olduser --jq .id") echo 42 ;;
    "api users/alice --jq .id") echo 7 ;;
    *"search/users"*"alice@example.com in:email"*) echo alice ;;
    *"search/users"*) echo "" ;;
    *) echo "unexpected gh $*" >&2; return 1 ;;
  esac
}

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
  {"author": {"id": 1, "login": "rgdevment"},
   "commit": {"author": {"name": "R", "email": "r@example.com"},
              "message": "feat: one\n\nbody\n\nCo-authored-by: New Person <99+newbie@users.noreply.github.com>\nco-authored-by:  Some Tool  <bot@tool.example>"}},
  {"author": null,
   "commit": {"author": {"name": "Unlinked", "email": "Unlinked@Example.com"}, "message": "fix: two"}},
  {"author": {"id": 1, "login": "rgdevment"},
   "commit": {"author": {"name": "R", "email": "r@example.com"},
              "message": "chore: three\n\nCo-authored-by: Old <olduser@users.noreply.github.com>\nCo-authored-by: Alice <alice@example.com>\nnot a trailer: Co-authored-by: Nobody <x@y.z>"}}
]'

same "every author and co-author, once" "$(people <<< "$commits")" "$(printf '%s\n' \
  $'account\t1\trgdevment' \
  $'email\t99+newbie@users.noreply.github.com\tNew Person' \
  $'email\talice@example.com\tAlice' \
  $'email\tbot@tool.example\tSome Tool' \
  $'email\tolduser@users.noreply.github.com\tOld' \
  $'email\tunlinked@example.com\tUnlinked' | sort -u)"

resolved=$(people <<< "$commits" | resolve)
same "an address resolves to its account, or stays an address" "$resolved" "$(printf '%s\n' \
  $'account\t1\trgdevment' \
  $'account\t42\tolduser' \
  $'account\t7\talice' \
  $'account\t99\tnewbie' \
  $'email\tbot@tool.example\tSome Tool' \
  $'email\tunlinked@example.com\tUnlinked' | sort -u -t $'\t' -k1,2)"

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
same "who still owes a signature" "$(unsigned "$signatures" <<< "$resolved")" "$(printf '%s\n' \
  $'account\t7\talice' \
  $'account\t99\tnewbie' \
  $'email\tbot@tool.example\tSome Tool' \
  $'email\tunlinked@example.com\tUnlinked')"

same "nobody owes anything on an empty pull request" "$(unsigned "$signatures" <<< "")" ""

NOT_SIGNED="Sign it." SIGN_PHRASE="I sign" DOCUMENT_URL="https://example.com/CLA.md"
said=$(worded "$(unsigned "$signatures" <<< "$resolved")")
same "the comment carries its marker first" "$(head -1 <<< "$said")" "$marker"
same "the comment names an account by mention" "$(grep -c '^- @alice$' <<< "$said")" 1
same "an address is never mentioned as a login" "$(grep -c '@bot@tool' <<< "$said")" 0
same "the phrase is quoted" "$(grep -c '^> I sign$' <<< "$said")" 1

exit $failed
