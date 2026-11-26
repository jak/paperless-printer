# Paperless Printer

[![CI](https://github.com/jak/paperless-printer/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/jak/paperless-printer/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**Print to PDF from any device.** Paperless Printer is a network printer in a container that
saves every job as a PDF. Phones, tablets and computers on your LAN discover it via
AirPrint/Bonjour (IPP), print to it, and the PDF lands in a directory, for example the
consume folder of [paperless-ngx](https://github.com/paperless-ngx/paperless-ngx). Runs with
Docker Compose or as an [Unraid app](#unraid).

Formerly `virtual-cups-printer`. Not affiliated with the paperless-ngx project.

- Works with iOS/iPadOS, macOS, Windows, Android and Linux (IPP / AirPrint)
- Colour PDFs; A4, Letter and other paper sizes
- Files appear **atomically** (never half-written) with the owner and permissions you choose
- File names come from the document title: `Invoice 42-job_7.pdf`
- Configured entirely through environment variables; admin over HTTPS only
- Multi-arch images (`linux/amd64`, `linux/arm64`)

## Quick start

```sh
git clone https://github.com/jak/paperless-printer && cd paperless-printer
echo 'choose-a-password' > admin_password.txt
docker compose up -d
```

Print to **Paperless Printer** from any device on the network. PDFs appear in `./output`.
The CUPS admin UI is at `https://<host>:631/admin` (user `admin`, the password above; the
certificate is self-signed).

[`docker-compose.yml`](docker-compose.yml) uses host networking, which is the simplest way to
make Bonjour discovery work. Other set-ups:

| Example | Use it when |
|---|---|
| [`docker-compose.yml`](docker-compose.yml) | One printer, host networking |
| [`examples/macvlan`](examples/macvlan/docker-compose.yml) | The printer should have its own LAN IP, or you run several printers on one host |
| [`examples/paperless`](examples/paperless/docker-compose.yml) | Feed paperless-ngx directly |
| [Unraid template](#unraid) | Run it on Unraid |

Without discovery (e.g. a bridge network with `-p 631:631`), add the printer manually as
`ipp://<host>:631/printers/Paperless_Printer`.

**Image tags:** the newest release is rebuilt weekly with Debian security updates, under its
exact version (`2.0.0`) and its floating tags (`2.0`, `2`, `latest`), so these tags are
*mutable*. Older releases are not rebuilt: follow `2` or `latest` to keep getting updates, or
pin `ghcr.io/jak/paperless-printer@sha256:…` if you need a fixed image.

## Unraid

[`templates/paperless-printer.xml`](templates/paperless-printer.xml) is an Unraid
template with the same hardening as the compose examples. Until it is listed in Community
Applications, add it from the Unraid terminal:

```sh
wget -O /boot/config/plugins/dockerMan/templates-user/my-paperless-printer.xml \
  https://raw.githubusercontent.com/jak/paperless-printer/master/templates/paperless-printer.xml
```

Then **Docker → Add Container → Template: paperless-printer**:

1. Keep **Network Type** on `br0` (or `eth0` when bridging is disabled) and set a **Fixed IP
   address** outside your router's DHCP range. Unraid runs its own mDNS service, so AirPrint
   discovery doesn't work on the Host network; on the Bridge network add the printer manually
   as `ipp://<server-ip>:631/printers/Paperless_Printer` and set *Allowed clients* to `all` or
   your LAN subnet.
2. Set an **Admin password**.
3. Point **Output folder** at where PDFs should go, e.g. paperless-ngx's consume folder.
   PDFs are owned by `99:100` (`nobody:users`) with mode `0666`, Unraid's share defaults; change
   PUID/PGID/UMASK to match another consumer.

The spool (queued jobs, job numbers, the printer's UUID and TLS certificate) is kept in
`/mnt/user/appdata/paperless-printer/spool`. With a custom network the Unraid server
itself can't reach the printer's IP unless **Settings → Docker → Host access to custom
networks** is enabled; other devices on the LAN can. `test/unraid.sh` starts the container
exactly as the template does and prints a test job.

The template advertises over IPv4 only (`AVAHI_IPV6=no`). On a `br0` with IPv6, Docker can give
the container the router's own IPv6 address (e.g. `<prefix>::1`, when the network's IPv6
gateway is the router's link-local address), and Avahi then renames the printer forever
(`Host name conflict, retrying with …`). If **Fixed IPv6 address** is shown, set it to an
unused address so the container doesn't take the router's.

## Configuration

Set these as environment variables; no rebuild is needed. Invalid values stop the container
at start with a clear message (exit code 64).

| Variable | Default | Description |
|---|---|---|
| `PRINTER_NAME` | `Paperless Printer` | Name shown to clients (at most 63 bytes, no `#`) |
| `PRINTER_ID` | `Paperless_Printer` | CUPS queue name (letters, digits, `_`, `-`); used in the URL `/printers/<id>` |
| `PRINTER_LOCATION` | *(empty)* | Location shown to clients |
| `PRINTER_UUID` | *random, kept in `/var/spool`* | Fixed UUID, if you need one. By default a random UUID is generated on first start and kept with the spool, so it stays stable while `/var/spool` is kept |
| `PAPER_SIZE` | `A4` | Default paper size, e.g. `A4`, `Letter`, `Legal`, `A5` |
| `TZ` | `UTC` | Time zone for timestamps |
| `OUTPUT_DIR` | `/mnt/output` | Where PDFs are written inside the container (mount a volume here). An existing directory's ownership is never changed; only a new or empty root-owned one (a fresh volume) is given to `PUID:PGID` |
| `PUID` / `PGID` | `1000` / `1000` | Owner of the PDFs. Match the consumer (e.g. paperless `USERMAP_UID`/`USERMAP_GID`) |
| `UMASK` | `0022` | Permission mask for PDFs (`0022` gives `0644`, `0027` gives `0640`, `0002` gives `0664`) |
| `OUTPUT_LABEL` | `2` | File naming: `0` = `Title.pdf`, `1` = `job_7-Title.pdf`, `2` = `Title-job_7.pdf`. Name clashes get `-1`, `-2`, …; existing files are never overwritten. Job numbers continue across restarts while `/var/spool` is kept (a volume, as in the compose examples) |
| `CUPS_ADMIN_USER` | `admin` | Admin user for the web UI and `lpadmin` |
| `CUPS_ADMIN_PASSWORD_FILE` | | File holding the admin password (Docker secret, **preferred**) |
| `CUPS_ADMIN_PASSWORD` | | Admin password. If neither is set, a random one is printed to the log at each start |
| `CUPS_ALLOW_FROM` | `all` | Space-separated CUPS addresses allowed to connect, e.g. `@LOCAL 192.168.1.0/24`. The compose examples use `@LOCAL` (the container's own subnets); keep `all` or list subnets when using a bridge network with published ports, where LAN clients don't look local |
| `CUPS_SERVER_ALIAS` | `*` | Host names clients may use. `*` is needed unless you list every name and IP (see [Security](#security)) |
| `CUPS_WEB_INTERFACE` | `yes` | Set `no` to disable the web UI |
| `CUPS_LOG_LEVEL` | `warn` | `error`, `warn`, `info`, `debug`, … |
| `AVAHI_ENABLED` | `yes` | Set `no` to disable Bonjour/AirPrint advertising |
| `AVAHI_IPV6` | `yes` | Set `no` to advertise over IPv4 only (no IPv6 address records). Use it when the log shows `Host name conflict, retrying with …` over and over (see [Troubleshooting](#troubleshooting)); the Unraid template sets `no` |
| `ADVERTISED_HOST` | *(empty)* | Host or IP for the admin link in the Bonjour record |

Configuration comes **only** from the environment: changes made in the CUPS web UI are lost
when the container restarts.

## How it works

```
client ──IPP──▶ cupsd ──▶ cups-pdf (Ghostscript) ──▶ /var/spool/vprint (staging)
                                                         │ PostProcessing hook marks it done
                                                         ▼
                              vprint-mover: claim under its final name (title from cupsd),
                              copy as .vprint-*.vprint-partial, chown PUID:PGID, chmod,
                              rename ──▶ OUTPUT_DIR
```

- `tini` is PID 1. `vprint-entrypoint` validates the environment, renders the
  [templates](rootfs/etc/vprint/templates), and supervises `cupsd`, `avahi-daemon` and
  `vprint-mover`. If any of them dies the container exits, so your restart policy recovers it.
- cups-pdf writes PDFs in place while Ghostscript runs, so they are staged first and published
  with an atomic rename. Consumers such as paperless never see a partial file.
- cups-pdf ignores Ghostscript failures, so a wrapper (`vprint-gs`) flags them and the mover
  logs `ERROR: PDF conversion failed for job N "Title"`. Without it, the job would show as
  completed with no file.
- cups-pdf 3.0.2 garbles titles it reads from PostScript, so the mover asks cupsd for each
  job's real title. Titles are sanitised: no path separators or control characters, at most
  100 bytes.
- `HEALTHCHECK` reports unhealthy if cupsd stops responding, the queue stops accepting jobs, a
  helper process dies, or finished PDFs can't be written to `OUTPUT_DIR` for over a minute (e.g.
  a full or read-only volume).
- All logs (CUPS, cups-pdf, Avahi, vprint) go to `docker logs`.

## Security

- Printing is anonymous, as with any network printer, so anyone who can reach port 631 can put
  a document into the output folder. The compose examples therefore set
  `CUPS_ALLOW_FROM=@LOCAL`. Firewall port 631 if the host is reachable from untrusted networks.
- Administration requires the admin password **and** TLS. Over plain HTTP, CUPS answers
  `426 Upgrade Required`, so the password never crosses the network unencrypted.
- No credentials are baked into the image. Passwords are stored as SHA-512 hashes at runtime.
- The compose examples drop all capabilities except the eight CUPS, cups-pdf and Avahi need,
  set `no-new-privileges`, and run with a **read-only root filesystem**. Scratch state lives on
  tmpfs at `/run` and `/tmp`; `/var/spool` is a named volume so PDFs still waiting to be
  written (for example while the output volume is full) and job numbers survive restarts.
  A tmpfs at `/var/spool` also works, but then queued PDFs are lost on restart.
- No TLS private key ships in the image: CUPS generates a self-signed certificate per
  container on first use and keeps it in `/var/spool/cups-tls`, so it survives restarts while
  `/var/spool` is kept. The certificate is named after the container's host name: a recreated
  container gets a new random host name, and so a new certificate, unless you set `hostname:`
  (not possible with host networking).
- `CUPS_SERVER_ALIAS=*` is the default because CUPS otherwise rejects every Host header except
  `localhost`, including the container's own IP. It weakens CUPS's DNS-rebinding protection for
  the *read-only* pages; admin actions still need TLS plus credentials. If you know every name
  and IP clients use, list them instead.
- Images are scanned with Trivy in CI, and the newest release is rebuilt weekly to pick up
  Debian security updates.

## Troubleshooting

| Symptom | Check |
|---|---|
| Printer not discovered | Use `network_mode: host` or macvlan. Bonjour doesn't cross bridge networks or VLANs without an mDNS reflector. Check `docker logs` for `Service "…" successfully established`. |
| Docker host can't reach a macvlan printer | Expected: macvlan isolates the host from its children. See the shim commands in [`examples/macvlan`](examples/macvlan/docker-compose.yml). |
| paperless doesn't pick up files | `PUID`/`PGID` must match paperless's `USERMAP_UID`/`USERMAP_GID`. Check with `ls -ln` on the consume directory. |
| PDFs are greyscale | Make sure the client has colour turned on; v2 advertises colour support and defaults to colour. Please report the client and OS. |
| Landscape pages come out sideways on a portrait page | The client lays the document out on the paper before sending it: macOS Preview and iOS turn landscape pages to fit portrait A4, and the printer saves exactly what they send. Choose landscape in the print dialog, or for a PDF you already have, copy it straight into the output/consume folder instead of printing it. |
| Poor OCR in paperless | Set `PAPERLESS_OCR_MODE=redo` (or `force`) in paperless (v3 values); printed PDFs often have a poor text layer. |
| A job "completed" but no PDF appeared | Look for `PDF conversion failed` in `docker logs`; the message includes Ghostscript's error. |
| Container keeps restarting | `docker logs`: configuration errors are explained and exit with code 64. |
| `Unable to bind` / Avahi warns about another mDNS stack | With host networking the container needs port 631 and shares mDNS with the host: stop the host's own CUPS (`cups.service`) and Avahi, or use the [macvlan example](examples/macvlan) to give the printer its own IP. |
| Log repeats `Host name conflict, retrying with <name>-2`, `-3`, … | Another device answers for one of the container's addresses, usually IPv6: Docker gave a macvlan/ipvlan container an address the router already uses (often `<prefix>::1`), or an mDNS reflector echoes the records back. Set `AVAHI_IPV6=no` to advertise over IPv4 only, and give the container a fixed IPv6 address (or fix the network's IPv6 range) so it doesn't duplicate the router's. |
| Need more detail | `CUPS_LOG_LEVEL=debug` |

## Upgrading from v1

See [CHANGELOG.md](CHANGELOG.md). In short: set an admin password, use `https://` for the
admin UI, set `PUID`/`PGID`, and stop editing `*.conf` files (use environment variables).

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md). Run `test/lint.sh`, `test/smoke.sh` and `test/unraid.sh`.
[Architecture decisions](docs/adr) are recorded as ADRs.

## License

[MIT](LICENSE). The image bundles third-party software under its own licences, including
[CUPS](https://github.com/OpenPrinting/cups) (Apache-2.0), cups-filters (Apache-2.0 / GPL /
MIT), [cups-pdf](https://www.cups-pdf.de/) (GPL-2.0-or-later),
[Ghostscript](https://www.ghostscript.com/) (AGPL-3.0), [Avahi](https://avahi.org/)
(LGPL-2.1) and [tini](https://github.com/krallin/tini) (MIT). Each image includes an SBOM.
Debian's copyright files are under `/usr/share/doc/*/copyright` in the image.
