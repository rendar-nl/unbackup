#!/usr/bin/env bash
set -euo pipefail

version="2026.08.03.1"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "${root}/dist"
pkg="${root}/dist/unbackup-${version}-x86_64-1.txz"

rm -f "${pkg}" "${pkg}.sha256"
tar --uid 0 --gid 0 --uname root --gname root -C "${root}/pkg" -cJf "${pkg}" .
(
  cd "${root}/dist"
  sha256sum "$(basename "${pkg}")" | tee "$(basename "${pkg}").sha256"
)
