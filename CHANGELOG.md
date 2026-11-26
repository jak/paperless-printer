# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed
- Releases no longer leave a `candidate-<run>` tag on the image: the image under test is pushed
  by digest only and gets just its version tags once it passes.

## [2.1.0] – 2026-11-26

### ⚠️ Renamed to Paperless Printer
- The project is now **paperless-printer** (`github.com/jak/paperless-printer`; the old URL
  redirects). Images are published as **`ghcr.io/jak/paperless-printer`**. The old image,
  `ghcr.io/jak/virtual-cups-printer`, stays at 2.0.0 and gets no more updates or weekly
  security rebuilds: change `image:` to `ghcr.io/jak/paperless-printer:2`. Nothing else
  changes; volumes and settings carry over.

### Added
- An Unraid template (`templates/paperless-printer.xml`), ready for Community Applications:
  its own LAN IP on `br0` for AirPrint discovery, `nobody:users` output, the compose examples'
  hardening, and the spool in appdata. CI starts the image with the template's settings.

## [2.0.0] – 2026-11-26

This fork is now independent of zix99/virtual-cups-printer and is MIT licensed.

### ⚠️ Breaking changes and upgrade notes
- **Admin credentials:** the baked-in `print`/`print` account is gone. Set
  `CUPS_ADMIN_PASSWORD_FILE` (Docker secret) or `CUPS_ADMIN_PASSWORD`; the user is
  `CUPS_ADMIN_USER` (default `admin`). If neither is set, a random password is printed
  to the log at each start.
- **Admin over HTTPS only:** the web admin pages and admin IPP operations now require TLS
  (CUPS's self-signed certificate). Use `https://<host>:631/admin`.
- **Output ownership:** PDFs are owned by `PUID:PGID` (default `1000:1000`) with mode from
  `UMASK` (default `0022`, giving `0644`). Previously files were `0600` or `0666` with
  inconsistent owners.
- **File names** now come from the job title, e.g. `Invoice 42-job_7.pdf`, instead of
  cups-pdf's garbled names (`stdin____bin_…-job_7.pdf`).
- **Configuration is environment-driven.** The repo's `*.conf` files moved to
  `rootfs/etc/vprint/templates/` and are rendered at start; changes made in the CUPS web UI
  do not persist.
- **Base image** is Debian 13 (trixie); the old bullseye image no longer builds.
- **The compose examples accept connections only from local networks** (`CUPS_ALLOW_FROM=@LOCAL`).
- **The compose examples keep `/var/spool` in a named volume**, so queued PDFs and job numbers
  survive restarts. Existing compose files with `tmpfs: [..., /var/spool]` keep working but
  lose queued PDFs on restart.
- **The image no longer declares `VOLUME /mnt/output`.** Mount your output directory
  explicitly (all examples do); a warning is logged when `OUTPUT_DIR` is not on a mounted volume.
- **`CUPS_ADMIN_USER` must not name an existing system account** (`nobody`, `www-data`, …), and
  the admin password must be a single line.

### Added
- Environment variables for printer name, ID, location and UUID, paper size, time zone,
  output dir, ownership and naming, log level, allow-list, server aliases, web UI, Avahi,
  and advertised host.
- Atomic publishing: PDFs appear in the output directory only once complete, so
  paperless-ngx never consumes a half-written file.
- Docker `HEALTHCHECK`; `tini` as PID 1; process supervision (the container exits if
  cupsd, Avahi or the mover dies).
- Logs from CUPS, cups-pdf and vprint in `docker logs`.
- Compose examples for host networking, macvlan and paperless-ngx, with least-privilege
  capabilities, `no-new-privileges` and a read-only root filesystem.
- Failed PDF conversions are reported in the log instead of silently producing no file.
- The healthcheck fails when finished PDFs can't be written to the output directory.
- Every build (including the weekly security rebuild) applies current Debian security updates
  on top of the digest-pinned base image.
- The release workflow tests the exact multi-arch image it publishes (lint, smoke test on
  amd64 and arm64 in both modes, Trivy) before promoting it to version tags.
- End-to-end smoke test and lint suite; CI on amd64 and arm64 with a weekly build; Trivy
  scanning; Dependabot; multi-arch images on GHCR with SBOM and provenance; weekly security
  rebuilds of the latest release.

### Fixed
- Image build broken by Debian bullseye end-of-life.
- Invalid and inconsistent Avahi TXT records; the colour capability is now advertised
  consistently.
- cupsd's DNS-SD errors (`Unable to communicate with avahi-daemon`): Avahi is the single
  discovery mechanism.
- Static printer UUID shared by every deployment: each deployment now gets a random UUID on
  first start, kept with `/var/spool` (or set `PRINTER_UUID`).
- Unbounded log files inside the container.
- Job titles containing commas or quotes no longer produce mangled file names.
- Stricter validation: `PRINTER_NAME` length and characters, exact `PAPER_SIZE` match, `TZ`
  (an empty value means UTC), `PUID`/`PGID` with leading zeros, system directories as
  `OUTPUT_DIR`.
- An existing output directory's ownership is no longer changed at start.
- A directory in the output folder with the same name as a new PDF no longer swallows it.
- Several containers can share one output directory without overwriting each other's files.
- Only known document extensions (`.docx`, `.txt`, …) are dropped from titles, so `example.com`
  stays `example.com.pdf`.
- `CUPS_ALLOW_FROM` accepts `@IF(name)` and bracketed IPv6 addresses, and wildcard entries are
  no longer glob-expanded; `ADVERTISED_HOST` is validated and IPv6 addresses are bracketed.
- The healthcheck fails when the queue is rejecting jobs.
- A finished PDF waiting in staging can no longer be overwritten by a later job that reuses its
  job number, and keeps the title it was printed with.
- `%` in `PRINTER_NAME` is advertised literally (Avahi no longer expands `%h`).
- The healthcheck now detects a stopped scheduler and a disabled queue reliably, and only reports
  stuck output when publishing is actually failing (not during a burst of jobs).
- PDFs finished while cupsd is starting wait for their title instead of being saved as `untitled`.
- Job numbers continue across restarts while `/var/spool` is kept (CUPS's cache lives there too).
- CUPS's self-signed certificate survives restarts (kept with the spool; a recreated container
  needs a fixed `hostname:` to keep it).
- Clearer start-up errors for an admin name that is an existing group, an empty
  `CUPS_SERVER_ALIAS`, and a `UMASK` that would make PDFs unreadable by their owner.
- PDFs cut off mid-conversion (e.g. the container was killed) are removed from staging after an
  hour instead of piling up; a finished PDF whose completion marker went missing is published.
- `TZ` accepts `:`-prefixed zone names and paths and POSIX rule strings.
- A file that keeps failing to publish is retried with back-off (up to a minute) instead of
  being copied again every second.
- Output folders where root can't set file owners (SMB/CIFS shares, root-squashed NFS) still
  receive PDFs; a warning explains that ownership and mode could not be applied.
- Scheduled rebuilds can no longer move `latest`/`X`/`X.Y` back to an older release, and carry the
  release tag's commit as their revision.
- A Debian snakeoil TLS private key, identical in every copy of the image, is no longer
  shipped (CUPS didn't use it; it generates a per-container certificate).

## 1.x

Original upstream releases (unversioned).
