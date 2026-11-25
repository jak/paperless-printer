# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased] – 2.0.0

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
- Static printer UUID shared by every deployment.
- Unbounded log files inside the container.
- Job titles containing commas or quotes no longer produce mangled file names.
- Stricter validation: `PRINTER_NAME` length and characters, exact `PAPER_SIZE` match, empty
  `TZ`, `PUID`/`PGID` with leading zeros, system directories as `OUTPUT_DIR`.
- An existing output directory's ownership is no longer changed at start.
- A directory in the output folder with the same name as a new PDF no longer swallows it.
- A Debian snakeoil TLS private key, identical in every copy of the image, is no longer
  shipped (CUPS didn't use it; it generates a per-container certificate).

## 1.x

Original upstream releases (unversioned).
