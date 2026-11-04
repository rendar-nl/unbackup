#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/unbackup-test.XXXXXX")"
trap 'rm -rf "${tmp}"' EXIT

mkdir -p "${tmp}/bin" "${tmp}/state" "${tmp}/templates" "${tmp}/destination"
printf '#!/usr/bin/env bash\nexit 0\n' > "${tmp}/bin/flock"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  "state='${tmp}/docker-state'" \
  "events='${tmp}/docker-events'" \
  'case "${1:-}" in' \
  '  status) [[ "$(cat "$state" 2>/dev/null)" == running ]] ;;' \
  '  stop) printf "stop\\n" >> "$events"; printf "stopped\\n" > "$state" ;;' \
  '  start) printf "start\\n" >> "$events"; printf "running\\n" > "$state" ;;' \
  '  *) exit 2 ;;' \
  'esac' > "${tmp}/bin/rc.docker"
chmod +x "${tmp}/bin/flock" "${tmp}/bin/rc.docker"
script="${tmp}/backup"
sed \
  -e "s#^config_file=.*#config_file=\"${tmp}/settings.json\"#" \
  -e "s#^state_dir=.*#state_dir=\"${tmp}/state\"#" \
  -e "s#^lock_file=.*#lock_file=\"${tmp}/unbackup.lock\"#" \
  -e "s#^docker_control=.*#docker_control=\"${tmp}/bin/rc.docker\"#" \
  -e "s#/boot/config/plugins/\${plugin}/unbackup.cron#${tmp}/unbackup.cron#" \
  -e "s#/boot/config/plugins/dockerMan/templates-user#${tmp}/templates#g" \
  "${root}/pkg/usr/local/emhttp/plugins/unbackup/scripts/backup" > "${script}"
chmod +x "${script}"

if ! PATH="${tmp}/bin:${PATH}" bash "${script}" --sync-cron; then
  echo "FAIL sync-cron-exit: cron synchronization returned failure" >&2
  exit 1
fi
printf 'PASS sync-cron-exit\n'

write_settings() {
  local appdata_root="$1" appdata_mode="$2" include_appdata="$3"
  local include_docker="$4" docker_source="$5"
  php -r '
    $settings = [
      "APPDATA_ROOT" => $argv[1],
      "APPDATA_MODE" => $argv[2],
      "DESTINATION" => $argv[3],
      "INCLUDE_APPDATA" => $argv[4],
      "INCLUDE_BOOT" => "no",
      "BOOT_SOURCE" => "",
      "INCLUDE_DOCKER_SOURCE" => $argv[5],
      "DOCKER_SOURCE" => $argv[6],
      "KEEP_LAST" => "4",
      "ZSTD_LEVEL" => "1",
      "EXCLUDE_FILE" => "",
      "BACKUP_FREQUENCY" => "disabled",
    ];
    file_put_contents($argv[7], json_encode($settings));
  ' "$appdata_root" "$appdata_mode" "${tmp}/destination" "$include_appdata" "$include_docker" "$docker_source" "${tmp}/settings.json"
}

assert_rejected() {
  local label="$1" expected="$2" output
  shift 2
  write_settings "$@"
  if output="$(PATH="${tmp}/bin:${PATH}" bash "${script}" --plan 2>&1)"; then
    printf 'FAIL %s: unsafe configuration was accepted\n%s\n' "$label" "$output" >&2
    exit 1
  fi
  if [[ "$output" != *"$expected"* ]]; then
    printf 'FAIL %s: expected %q in output\n%s\n' "$label" "$expected" "$output" >&2
    exit 1
  fi
  printf 'PASS %s\n' "$label"
}

assert_accepted() {
  local label="$1" output
  shift
  write_settings "$@"
  if ! output="$(PATH="${tmp}/bin:${PATH}" bash "${script}" --plan 2>&1)"; then
    printf 'FAIL %s: supported configuration was rejected\n%s\n' "$label" "$output" >&2
    exit 1
  fi
  printf 'PASS %s\n' "$label"
}

missing_root="${tmp}/missing-appdata"
assert_rejected missing-appdata-root "Missing appdata root" \
  "$missing_root" all yes no ""

empty_root="${tmp}/empty-appdata"
mkdir -p "$empty_root"
assert_rejected empty-template-selection "No appdata paths selected" \
  "$empty_root" templates yes no ""

docker_image="${tmp}/docker.img"
: > "$docker_image"
assert_accepted regular-file-docker-source \
  "$empty_root" templates no yes "$docker_image"

docker_directory="${tmp}/docker-directory"
mkdir -p "$docker_directory"
assert_accepted directory-docker-source \
  "$empty_root" templates no yes "$docker_directory"

printf '#!/usr/bin/env bash\nprintf partial-data\nexit 1\n' > "${tmp}/bin/tar"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'output=""' \
  'while (($#)); do' \
  '  if [[ "$1" == "-o" ]]; then output="$2"; shift 2; else shift; fi' \
  'done' \
  'cat > "$output"' > "${tmp}/bin/zstd"
chmod +x "${tmp}/bin/tar" "${tmp}/bin/zstd"

boot_source="${tmp}/boot"
mkdir -p "$boot_source"
: > "${boot_source}/config.txt"
php -r '
  $settings = [
    "APPDATA_ROOT" => $argv[1],
    "APPDATA_MODE" => "templates",
    "DESTINATION" => $argv[2],
    "INCLUDE_APPDATA" => "no",
    "INCLUDE_BOOT" => "yes",
    "BOOT_SOURCE" => $argv[3],
    "INCLUDE_DOCKER_SOURCE" => "no",
    "DOCKER_SOURCE" => "",
    "KEEP_LAST" => "4",
    "ZSTD_LEVEL" => "1",
    "EXCLUDE_FILE" => "",
    "BACKUP_FREQUENCY" => "disabled",
  ];
  file_put_contents($argv[4], json_encode($settings));
' "$empty_root" "${tmp}/destination" "$boot_source" "${tmp}/settings.json"

if PATH="${tmp}/bin:${PATH}" bash "${script}" >/dev/null 2>&1; then
  echo "FAIL failed-archive-cleanup: injected tar failure was accepted" >&2
  exit 1
fi
if find "${tmp}/destination" -maxdepth 1 -type f \( -name '*.partial' -o -name '*.tar.zst' \) | grep -q .; then
  echo "FAIL failed-archive-cleanup: failed output was published or retained" >&2
  exit 1
fi
if ! grep -q '^LAST_EXIT_CODE=1$' "${tmp}/state/status.env"; then
  echo "FAIL failed-archive-cleanup: failure status was not recorded" >&2
  exit 1
fi
printf 'PASS failed-archive-cleanup\n'

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'if [[ " $* " == *" -tf "* ]]; then cat >/dev/null; else printf archive-data; fi' > "${tmp}/bin/tar"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'if [[ "${1:-}" == "-dc" ]]; then cat "$2"; exit; fi' \
  'output=""' \
  'while (($#)); do' \
  '  if [[ "$1" == "-o" ]]; then output="$2"; shift 2; else shift; fi' \
  'done' \
  'cat > "$output"' > "${tmp}/bin/zstd"
printf '#!/usr/bin/env bash\nexit 1\n' > "${tmp}/bin/ln"
chmod +x "${tmp}/bin/tar" "${tmp}/bin/zstd" "${tmp}/bin/ln"

if ! PATH="${tmp}/bin:${PATH}" bash "${script}" >/dev/null 2>&1; then
  echo "FAIL unsupported-latest-symlink: optional symlink failure failed the backup" >&2
  exit 1
fi
if ! find "${tmp}/destination" -maxdepth 1 -type f -name '*.tar.zst' | grep -q .; then
  echo "FAIL unsupported-latest-symlink: verified archive was not published" >&2
  exit 1
fi
if ! grep -q '^LAST_EXIT_CODE=0$' "${tmp}/state/status.env"; then
  echo "FAIL unsupported-latest-symlink: success status was not recorded" >&2
  exit 1
fi
printf 'PASS unsupported-latest-symlink\n'

printf '%s\n' \
  '#!/usr/bin/env bash' \
  "events='${tmp}/capture-events'" \
  "fail='${tmp}/fail-copy'" \
  'printf "reflink\\n" >> "$events"' \
  '[[ ! -e "$fail" ]] || exit 91' \
  'args=()' \
  'for arg in "$@"; do' \
  '  case "$arg" in --reflink=*|--sparse=*|--one-file-system) ;; *) args+=("$arg") ;; esac' \
  'done' \
  '/bin/cp "${args[@]}"' > "${tmp}/bin/cp"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "---------------C------"' > "${tmp}/bin/lsattr"
printf '%s\n' '#!/usr/bin/env bash' "printf '%s\\n' nocow >> '${tmp}/attribute-events'" > "${tmp}/bin/chattr"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  "directory='${docker_directory}'" \
  "mountpoint='${tmp}'" \
  'field=""' \
  'while (($#)); do' \
  '  if [[ "$1" == "-o" ]]; then field="$2"; shift 2; else source="$1"; shift; fi' \
  'done' \
  'case "$field:$source" in' \
  '  FSTYPE:*docker-directory) printf "btrfs\\n" ;;' \
  '  FSTYPE:*) printf "xfs\\n" ;;' \
  '  TARGET:*) printf "%s\\n" "$mountpoint" ;;' \
  '  SOURCE:*) printf "testpool/docker\\n" ;;' \
  'esac' > "${tmp}/bin/findmnt"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  "events='${tmp}/capture-events'" \
  "directory='${docker_directory}'" \
  "nested='${tmp}/nested-subvolumes'" \
  'case "$1 $2" in' \
  '  "subvolume show") exit 1 ;;' \
  '  "subvolume create") mkdir -p "$3" ;;' \
  '  "subvolume list") if [[ -f "$nested" ]]; then cat "$nested"; fi ;;' \
  '  "subvolume snapshot")' \
  '    destination="${@: -1}"' \
  '    mkdir -p "$destination"' \
  '    /bin/cp -a "$directory" "$destination/$(basename "$directory")"' \
  '    printf "snapshot\\n" >> "$events"' \
  '    ;;' \
  '  "subvolume delete") /bin/rm -rf "$3" ;;' \
  '  *) exit 2 ;;' \
  'esac' > "${tmp}/bin/btrfs"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  "if [[ \" \$* \" == *\" -tf \"* ]]; then cat >/dev/null; else printf '%s\\n' \"\$*\" > '${tmp}/tar-args'; printf archive-data; fi" > "${tmp}/bin/tar"
chmod +x "${tmp}/bin/cp" "${tmp}/bin/lsattr" "${tmp}/bin/chattr" "${tmp}/bin/findmnt" "${tmp}/bin/btrfs" "${tmp}/bin/tar"

assert_docker_capture() {
  local label="$1" source="$2" expected_event="$3" expected_path="$4" events
  write_settings "$empty_root" templates no yes "$source"
  : > "${tmp}/capture-events"
  : > "${tmp}/attribute-events"
  : > "${tmp}/docker-events"
  rm -f "${tmp}/fail-copy"
  if ! PATH="${tmp}/bin:${PATH}" bash "${script}" >/dev/null 2>&1; then
    printf 'FAIL %s: consistent Docker capture failed\n' "$label" >&2
    exit 1
  fi
  events="$(cat "${tmp}/capture-events")"
  if [[ "$events" != "$expected_event" ]]; then
    printf 'FAIL %s: expected %q; got %q\n' "$label" "$expected_event" "$events" >&2
    exit 1
  fi
  if [[ -s "${tmp}/docker-events" ]]; then
    printf 'FAIL %s: Docker service control was invoked\n' "$label" >&2
    exit 1
  fi
  if [[ -f "$(realpath "$source")" && "$(cat "${tmp}/attribute-events")" != nocow ]]; then
    printf 'FAIL %s: image capture did not preserve NOCOW state\n' "$label" >&2
    exit 1
  fi
  if ! grep -q "$expected_path" "${tmp}/tar-args"; then
    printf 'FAIL %s: archive did not use the stable Docker capture\n' "$label" >&2
    exit 1
  fi
  if ! grep -Fq "#${source#/}" "${tmp}/tar-args"; then
    printf 'FAIL %s: archive path did not preserve the configured Docker source\n' "$label" >&2
    exit 1
  fi
  if find "${tmp}/.unbackup-docker-captures" "${tmp}/.unbackup-docker-snapshots" -mindepth 1 -print 2>/dev/null | grep -q .; then
    printf 'FAIL %s: Docker capture was not cleaned up\n' "$label" >&2
    exit 1
  fi
  printf 'PASS %s\n' "$label"
}

printf 'image-data\n' > "$docker_image"
printf 'directory-data\n' > "${docker_directory}/layer"
assert_docker_capture regular-file-docker-capture "$docker_image" reflink '\.unbackup-docker-captures'
docker_image_alias="${tmp}/docker-image-alias"
ln -s "$docker_image" "$docker_image_alias"
assert_docker_capture resolved-image-file-capture "$docker_image_alias" reflink '\.unbackup-docker-captures'
assert_docker_capture directory-docker-capture "$docker_directory" snapshot '\.unbackup-docker-snapshots'

printf 'ID 257 gen 9 top level 5 path layers/abc\n' > "${tmp}/nested-subvolumes"
write_settings "$empty_root" templates no yes "$docker_directory"
: > "${tmp}/capture-events"
: > "${tmp}/docker-events"
rm -f "${tmp}/tar-args"
if output="$(PATH="${tmp}/bin:${PATH}" bash "${script}" 2>&1)"; then
  echo "FAIL nested-docker-subvolume: incomplete Docker capture was accepted" >&2
  exit 1
fi
if [[ "$output" != *"nested Btrfs subvolumes"* ]]; then
  printf 'FAIL nested-docker-subvolume: expected rejection message\n%s\n' "$output" >&2
  exit 1
fi
if [[ -e "${tmp}/tar-args" ]]; then
  echo "FAIL nested-docker-subvolume: archive was created from an incomplete snapshot" >&2
  exit 1
fi
if ! grep -q '^LAST_EXIT_CODE=1$' "${tmp}/state/status.env"; then
  echo "FAIL nested-docker-subvolume: failure status was not recorded" >&2
  exit 1
fi
if find "${tmp}/.unbackup-docker-snapshots" -mindepth 1 -print 2>/dev/null | grep -q .; then
  echo "FAIL nested-docker-subvolume: Docker snapshot was not cleaned up" >&2
  exit 1
fi
rm -f "${tmp}/nested-subvolumes"
printf 'PASS nested-docker-subvolume\n'

write_settings "$empty_root" templates no yes "$docker_image"
: > "${tmp}/capture-events"
: > "${tmp}/docker-events"
if ! PATH="${tmp}/bin:${PATH}" bash "${script}" --check >/dev/null 2>&1; then
  echo "FAIL docker-capture-check: check mode did not exercise Docker capture" >&2
  exit 1
fi
if [[ "$(cat "${tmp}/capture-events")" != reflink || -s "${tmp}/docker-events" ]]; then
  echo "FAIL docker-capture-check: check mode was not an online capture" >&2
  exit 1
fi
printf 'PASS docker-capture-check\n'

write_settings "$empty_root" templates no yes "$docker_image"
: > "${tmp}/capture-events"
: > "${tmp}/fail-copy"
if PATH="${tmp}/bin:${PATH}" bash "${script}" >/dev/null 2>&1; then
  echo "FAIL docker-restart-after-capture-failure: injected copy failure was accepted" >&2
  exit 1
fi
if [[ -s "${tmp}/docker-events" ]]; then
  echo "FAIL live-capture-failure: Docker service control was invoked" >&2
  exit 1
fi
if find "${tmp}/.unbackup-docker-captures" -mindepth 1 -print 2>/dev/null | grep -q .; then
  echo "FAIL live-capture-failure: failed capture was not cleaned up" >&2
  exit 1
fi
printf 'PASS live-capture-failure\n'
