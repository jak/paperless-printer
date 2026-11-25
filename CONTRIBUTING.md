# Contributing

## Layout

| Path | What it is |
|---|---|
| `Dockerfile` | Image definition (Debian trixie-slim, CUPS, cups-pdf, Avahi, tini) |
| `rootfs/usr/local/bin/vprint-entrypoint` | Validates env vars, renders config, supervises cupsd, Avahi and the mover |
| `rootfs/usr/local/bin/vprint-mover` | Publishes finished PDFs atomically into `OUTPUT_DIR` with the right owner, mode and name |
| `rootfs/usr/local/bin/vprint-postprocess` | cups-pdf hook that marks a PDF as finished |
| `rootfs/usr/local/bin/vprint-gs` | Ghostscript wrapper that reports failed conversions |
| `rootfs/usr/local/bin/vprint-healthcheck` | Docker `HEALTHCHECK` |
| `rootfs/etc/vprint/templates/` | Config templates rendered with `envsubst` at start |
| `test/smoke.sh` | End-to-end test: prints over IPP from a second container and checks the results |
| `test/lint.sh` | hadolint, shellcheck, compose and XML validation |
| `docs/adr/` | Architecture decisions |

## Runtime state

The root filesystem can be read-only. Everything written at runtime goes to `/run`, `/tmp` or
`/var/spool`. `/etc/cups`, `/etc/avahi`, `/etc/papersize` and `/etc/{passwd,group,shadow,gshadow}`
are symlinks into `/run/vprint`, seeded on each start from `/usr/local/share/vprint/dist`.
Don't `apt-get install` in a derived image without restoring those first.

## Development loop

```sh
test/lint.sh                 # static checks (needs Docker + python3)
test/smoke.sh                # builds vprint:smoke and runs the end-to-end suite (~2 min)
docker build -t vprint:dev . && docker run --rm -it -p 631:631 -e CUPS_ADMIN_PASSWORD=dev vprint:dev
```

Every behaviour change needs a smoke-test check. CI runs lint and, in parallel, builds the image and runs the smoke test on amd64 and arm64 twice: with Docker's default settings, and hardened (minimal capabilities, `no-new-privileges`, read-only root). A Trivy scan follows the build. The release workflow builds the multi-arch image once, runs the same gates against that exact image, and only then promotes its digest to the version tags.

## Commits and releases

- Use [Conventional Commits](https://www.conventionalcommits.org/) (`fix:`, `feat:`, `feat!:`/`BREAKING CHANGE:`, `docs:`, `ci:`, `build(deps):`)
- Add user-visible changes to `CHANGELOG.md` under **Unreleased**
- Release: move the Unreleased notes under a new version heading, commit, then `git tag vX.Y.Z && git push origin vX.Y.Z`. The Release workflow pushes a `candidate-<run>` image (amd64 + arm64, SBOM, provenance), runs lint, the smoke test (both modes, both architectures) and Trivy against it, then points `X.Y.Z` (plus `X.Y`, `X` and `latest` when it's the newest in that line) at the tested digest and creates the GitHub release. Candidate tags can be deleted from the package page.
- The same workflow rebuilds the newest release weekly, so Debian security fixes ship without a code change. Version tags are therefore **mutable**; pin `image@sha256:…` for immutability.
