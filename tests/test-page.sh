#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
page="${root}/pkg/usr/local/emhttp/plugins/unbackup/UnBackup.page"

assert_contains() {
  grep -Fq -- "$1" "${page}" || {
    printf 'Missing expected page content: %s\n' "$1" >&2
    exit 1
  }
}

assert_absent() {
  if grep -Fq -- "$1" "${page}"; then
    printf 'Unexpected page content: %s\n' "$1" >&2
    exit 1
  fi
}

assert_contains 'Docker template folders'
assert_contains 'Entire appdata root'
assert_contains 'class="narrow unbackup-path-picker"'
assert_contains 'data-frequencies="weekly"'
assert_contains 'data-frequencies="monthly"'
assert_contains "jquery.filetree.js"
assert_contains "\$('.unbackup-path-picker').fileTreeAttach();"
assert_contains 'updateScheduleFields();'
assert_absent 'value="preview"'
assert_absent 'value="check"'
assert_absent "\$action === 'preview'"
assert_absent "\$action === 'check'"

printf 'UnBackup page checks passed.\n'
