#!/usr/bin/env bash
set -euo pipefail

version="2026.08.03.2"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
release_timestamp="${version:0:4}${version:5:2}${version:8:2}0000"
mkdir -p "${root}/dist"
pkg="${root}/dist/unbackup-${version}-x86_64-1.txz"
stage="$(mktemp -d "${TMPDIR:-/tmp}/unbackup-build.XXXXXX")"
trap 'rm -rf "${stage}"' EXIT

rm -f "${pkg}" "${pkg}.sha256"
cp -a "${root}/pkg/." "${stage}/"
cp -p "${root}/LICENSE" "${stage}/usr/local/emhttp/plugins/unbackup/LICENSE"
TZ=UTC find "${stage}" -exec touch -t "${release_timestamp}" {} +
tar --uid 0 --gid 0 --uname root --gname root -C "${stage}" -cJf "${pkg}" .
(
  cd "${root}/dist"
  sha256sum "$(basename "${pkg}")" | tee "$(basename "${pkg}").sha256"
)
