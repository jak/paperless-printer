#!/usr/bin/env bash
# Start the container the way Unraid does from templates/paperless-printer.xml (its default
# values, ExtraParams and appdata paths), print a job, and check the result survives a re-create.
#
# Usage: test/unraid.sh                    # builds vprint:smoke from the working tree
#        IMAGE=ghcr.io/... test/unraid.sh  # tests an existing image (no build)
set -euo pipefail

cd "$(dirname "$0")/.."

IMAGE=${IMAGE:-}
NAME="vprint-unraid-$$"
failures=0

pass() { printf '  \033[32mok\033[0m   %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; failures=$((failures + 1)); }
check() { local desc=$1; shift; if "$@"; then pass "$desc"; else fail "$desc"; fi; }
section() { printf '\n== %s\n' "$*"; }

cleanup() {
  local rc=$?
  if ((rc != 0 || failures != 0)) && docker inspect "$NAME" >/dev/null 2>&1; then
    echo; echo "---- server logs ----"; docker logs "$NAME" 2>&1 | tail -60
  fi
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  docker volume rm -f "$NAME-output" "$NAME-spool" >/dev/null 2>&1 || true
  docker network rm "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

if [[ -z $IMAGE ]]; then
  IMAGE=vprint:smoke
  section "build $IMAGE"
  docker build -q -t "$IMAGE" . >/dev/null
fi

section "template"
check "template is valid and matches the image" python3 test/unraid-template.py check
args=()
while IFS= read -r a; do args+=("$a"); done < <(python3 test/unraid-template.py args "$NAME")
# The template leaves the admin password empty; Unraid users fill it in.
args+=(-e CUPS_ADMIN_PASSWORD=unraid-pass)

wait_healthy() {
  local status
  for _ in $(seq 1 60); do
    status=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}/{{.State.Status}}' "$NAME" 2>/dev/null || true)
    [[ $status == healthy/running ]] && return 0
    [[ $status == */exited ]] && return 1
    sleep 1
  done
  return 1
}
client() { docker run --rm -i --network "$NAME" --entrypoint "" "$IMAGE" "$@"; }
in_server() { docker exec "$NAME" "$@"; }
pdfs() { in_server find /mnt/output -maxdepth 1 -type f -name '*.pdf' -printf '%f %U:%G %m\n'; }
start() { docker run -d "${args[@]}" "$IMAGE" >/dev/null; }

section "start with the template's settings"
docker network create "$NAME" >/dev/null
start
check "container becomes healthy" wait_healthy
check "avahi publishes the service" bash -c "docker logs '$NAME' 2>&1 | grep -q 'successfully established'"
check "root filesystem is read-only" bash -c "! docker exec '$NAME' touch /usr/vprint-rw-test 2>/dev/null"

section "print from the LAN (allowed by @LOCAL)"
printf 'Hello from Unraid\n' | client lp -h "$NAME:631" -d Paperless_Printer -t "Unraid Test" >/dev/null
for _ in $(seq 1 60); do [[ -n $(pdfs) ]] && break; sleep 1; done
printf '  files: %s\n' "$(pdfs)"
check "PDF is owned by nobody:users (99:100) with mode 666" bash -c "[[ \$(docker exec '$NAME' find /mnt/output -maxdepth 1 -name 'Unraid Test-job_*.pdf' -printf '%U:%G %m') == '99:100 666' ]]"
check "admin pages ask for a password over HTTPS" bash -c \
  "[[ \$(docker run --rm --network '$NAME' curlimages/curl:8.11.1 -sk -o /dev/null -w '%{http_code}' https://$NAME:631/admin) == 401 ]]"

uuid() { in_server cat /var/spool/vprint-state/printer-uuid; }
# Fails (and stops the test) if there is no certificate, so an empty match can't pass.
cert() { in_server sh -c 'ls /var/spool/cups-tls/*.crt >/dev/null && cat /var/spool/cups-tls/*.crt' | sha256sum; }
before_uuid=$(uuid)
before_cert=$(cert)

section "re-create the container (an Unraid update)"
# Unraid stops a container (SIGTERM, CUPS saves its state) before removing it on an update.
docker stop "$NAME" >/dev/null && docker rm "$NAME" >/dev/null
start
check "container becomes healthy again" wait_healthy
check "printer UUID is kept in the spool" test "$(uuid)" = "$before_uuid"
check "TLS certificate is kept (fixed hostname)" test "$(cert)" = "$before_cert"
printf 'Second job\n' | client lp -h "$NAME:631" -d Paperless_Printer -t "After Update" >/dev/null
for _ in $(seq 1 60); do pdfs | grep -q 'After Update' && break; sleep 1; done
check "job numbers continue after the update" bash -c "docker exec '$NAME' ls /mnt/output | grep -qx 'After Update-job_2.pdf'"

echo
if ((failures)); then echo "$failures check(s) failed"; exit 1; fi
echo "all checks passed"
