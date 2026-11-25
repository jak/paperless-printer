#!/usr/bin/env bash
# Static checks. Runs the same way locally and in CI; only needs Docker and python3.
set -euo pipefail
cd "$(dirname "$0")/.."

HADOLINT_IMAGE=hadolint/hadolint:v2.15.1
SHELLCHECK_IMAGE=koalaman/shellcheck:v0.11.0
status=0
run() { printf '\n== %s\n' "$1"; shift; if "$@"; then echo "ok"; else echo "FAILED"; status=1; fi; }

shell_scripts=(
  rootfs/usr/local/bin/vprint-entrypoint
  rootfs/usr/local/bin/vprint-healthcheck
  rootfs/usr/local/bin/vprint-mover
  rootfs/usr/local/bin/vprint-postprocess
  test/smoke.sh
  test/lint.sh
)

run "hadolint Dockerfile" docker run --rm -i "$HADOLINT_IMAGE" hadolint - <Dockerfile
run "shellcheck" docker run --rm -v "$PWD:/mnt:ro" -w /mnt "$SHELLCHECK_IMAGE" --severity=style "${shell_scripts[@]}"
# shellcheck disable=SC2016 # expanded by the inner bash
run "scripts are executable" bash -c 'for f in "$@"; do [[ -x $f ]] || { echo "not executable: $f"; exit 1; }; done' _ "${shell_scripts[@]}"

# shellcheck disable=SC2329 # invoked via run
compose_check() {
  local f created=
  [[ -e admin_password.txt ]] || { : >admin_password.txt; created=1; }
  for f in docker-compose.yml examples/*/docker-compose.yml; do
    docker compose -f "$f" config -q || { echo "invalid: $f"; [[ -z $created ]] || rm -f admin_password.txt; return 1; }
  done
  [[ -z $created ]] || rm -f admin_password.txt
}
run "docker compose config" compose_check

run "avahi service template is well-formed XML" python3 -c '
import sys, xml.dom.minidom
xml.dom.minidom.parse(sys.argv[1])' rootfs/etc/vprint/templates/vprint.service

exit $status
