# UnBackup

UnBackup creates compressed Unraid backups while Docker remains running. It can include:

- appdata through a read-only Btrfs snapshot;
- `/boot/config` or another configured boot source;
- Docker image-file storage through a live reflink or ZFS snapshot;
- Docker directory storage through a Btrfs or ZFS snapshot.

Unsupported storage layouts fail closed instead of falling back to a live file copy. Backups are filesystem-consistent snapshots; applications that need transaction-aware dumps should still create those dumps inside appdata before UnBackup runs.

## Storage support

| Source | Supported online capture |
| --- | --- |
| Appdata | Btrfs |
| Docker image file | Filesystem reflink or ZFS snapshot |
| Docker directory | Btrfs or ZFS snapshot |
| Boot configuration | Direct archive read |

## Build and test

```bash
bash tests/test-backup.sh
bash build.sh
```

The package and its SHA-256 checksum are written to `dist/`.

## Installation

In Unraid, open **Plugins → Install Plugin** and enter:

```text
https://raw.githubusercontent.com/rendar-nl/unbackup/main/unbackup.plg
```

The manifest downloads the versioned package from the corresponding GitHub release and verifies its SHA-256 checksum.

## Manual installation fallback

To install without remote access, copy both files to the Unraid server:

```text
/boot/config/plugins/unbackup.plg
/boot/config/plugins/unbackup/unbackup-<version>-x86_64-1.txz
```

Then install it from an Unraid shell:

```bash
plugin install /boot/config/plugins/unbackup.plg
```

Open **Utilities → UnBackup**, save the server-specific paths, and run **Validate**, **Preview**, and **Check** before the first backup.

## Command line

The installed backup command is:

```text
/usr/local/emhttp/plugins/unbackup/scripts/backup
```

It accepts `--validate`, `--plan`, `--check`, and `--sync-cron`. Running it without an option starts a backup.

## Source

The canonical repository is <https://github.com/rendar-nl/unbackup>.
