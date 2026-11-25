# Contributing

## Layout

| Path | What it is |
|---|---|
| `Dockerfile` | Image definition (Debian trixie-slim, CUPS, cups-pdf, Avahi, tini) |
| `rootfs/usr/local/bin/vprint-entrypoint` | Validates env vars, renders config, supervises cupsd, Avahi and the mover |
| `rootfs/usr/local/bin/vprint-mover` | Publishes finished PDFs atomically into `OUTPUT_DIR` with the right owner, mode and name |
| `rootfs/usr/local/bin/vprint-postprocess` | cups-pdf hook that marks a PDF as finished |
| `rootfs/usr/local/bin/vprint-healthcheck` | Docker `HEALTHCHECK` |
| `rootfs/etc/vprint/templates/` | Config templates rendered with `envsubst` at start |
| `test/smoke.sh` | End-to-end test: prints over IPP from a second container and checks the results |
| `test/lint.sh` | hadolint, shellcheck, compose and XML validation |
| `docs/adr/` | Architecture decisions |

## Development loop

```sh
test/lint.sh                 # static checks (needs Docker + python3)
test/smoke.sh                # builds vprint:smoke and runs the end-to-end suite (~2 min)
docker build -t vprint:dev . && docker run --rm -it -p 631:631 -e CUPS_ADMIN_PASSWORD=dev vprint:dev
```

Every behaviour change needs a smoke-test check. CI runs lint, then the smoke test on amd64 and arm64 with default and hardened capabilities, then a Trivy scan.

## Commits and releases

- Use [Conventional Commits](https://www.conventionalcommits.org/) (`fix:`, `feat:`, `feat!:`/`BREAKING CHANGE:`, `docs:`, `ci:`, `build(deps):`)
- Add user-visible changes to `CHANGELOG.md` under **Unreleased**
- Release: move the Unreleased notes under a new version heading, commit, then `git tag vX.Y.Z && git push origin vX.Y.Z`. The Release workflow runs the smoke test, publishes `ghcr.io/jak/virtual-cups-printer:{X.Y.Z,X.Y,X,latest}` for amd64 and arm64 with SBOM and provenance, and creates the GitHub release.
- The same workflow rebuilds the latest release weekly, so Debian security fixes ship without a code change.
