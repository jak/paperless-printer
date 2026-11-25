#!/usr/bin/env bash
# End-to-end smoke test: start the printer, print over IPP from a second container,
# and check the PDFs, permissions, auth, supervision and shutdown behaviour.
#
# Usage: test/smoke.sh                 # builds vprint:smoke from the working tree
#        IMAGE=ghcr.io/... test/smoke.sh   # tests an existing image (no build)
#        SERVER_ARGS="--cap-drop ALL ..." test/smoke.sh   # extra `docker run` args for the server
set -euo pipefail

cd "$(dirname "$0")/.."

IMAGE=${IMAGE:-}
read -r -a SERVER_ARGS <<<"${SERVER_ARGS:-}"
CURL_IMAGE=curlimages/curl:8.11.1
RUN_ID="vprint-smoke-$$"
NET=$RUN_ID
SERVER=$RUN_ID-server
VOL=$RUN_ID-out
ADMIN_PASSWORD="smoke-$RANDOM-pass"
failures=0

pass() { printf '  \033[32mok\033[0m   %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; failures=$((failures + 1)); }
check() { local desc=$1; shift; if "$@"; then pass "$desc"; else fail "$desc"; fi; }
section() { printf '\n== %s\n' "$*"; }

cleanup() {
  local rc=$?
  if ((rc != 0 || failures != 0)) && docker inspect "$SERVER" >/dev/null 2>&1; then
    echo; echo "---- server logs ----"; docker logs "$SERVER" 2>&1 | tail -60
  fi
  docker rm -f "$SERVER" "$SERVER-bad" "$SERVER-sup" >/dev/null 2>&1 || true
  docker volume rm -f "$VOL" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -f "${SECRET_FILE:-}"
}
trap cleanup EXIT

if [[ -z $IMAGE ]]; then
  IMAGE=vprint:smoke
  section "build $IMAGE"
  docker build -q -t "$IMAGE" . >/dev/null
fi

# Run a command in a throwaway client container on the test network (CUPS client tools).
client() { docker run --rm -i --network "$NET" --entrypoint "" "$IMAGE" "$@"; }
curl_code() { docker run --rm --network "$NET" "$CURL_IMAGE" -s -o /dev/null -w '%{http_code}' "$@"; }
in_server() { docker exec "$SERVER" "$@"; }

wait_healthy() {
  local name=$1 i status
  for i in $(seq 1 60); do
    status=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}/{{.State.Status}}' "$name" 2>/dev/null || true)
    [[ $status == healthy/running ]] && return 0
    [[ $status == */exited ]] && return 1
    sleep 1
  done
  return 1
}

section "start server"
docker network create "$NET" >/dev/null
SECRET_FILE=$(mktemp)
printf '%s\n' "$ADMIN_PASSWORD" >"$SECRET_FILE"
chmod 0644 "$SECRET_FILE"
docker volume create "$VOL" >/dev/null
docker run -d --name "$SERVER" --network "$NET" ${SERVER_ARGS[@]+"${SERVER_ARGS[@]}"} \
  -e CUPS_ADMIN_PASSWORD_FILE=/run/secrets/admin -v "$SECRET_FILE:/run/secrets/admin:ro" \
  -e PRINTER_NAME="Smoke & Test Printer" \
  -e PUID=1234 -e PGID=2345 -e UMASK=0027 \
  -e PAPER_SIZE=Letter -e TZ=Europe/London \
  -v "$VOL:/mnt/output" "$IMAGE" >/dev/null
check "container becomes healthy" wait_healthy "$SERVER"
check "CUPS logs reach docker logs" bash -c "docker logs '$SERVER' 2>&1 | grep -q 'vprint-mover: watching'"
check "avahi publishes the service" bash -c "docker logs '$SERVER' 2>&1 | grep -q 'successfully established'"
check "avahi service file is valid XML with escaped name" \
  bash -c "docker exec '$SERVER' grep -q 'Smoke &amp; Test Printer' /etc/avahi/services/vprint.service"
check "PPD default paper size follows PAPER_SIZE" \
  bash -c "docker exec '$SERVER' grep -q '^\*DefaultPageSize: Letter' /etc/cups/ppd/Paperless_Printer.ppd"
check "printer UUID is derived (not the old static one)" \
  bash -c "! docker exec '$SERVER' grep -q b5105127 /etc/cups/printers.conf"

section "print over the network"
printf 'Hello from the smoke test\n' | client lp -h "$SERVER:631" -d Paperless_Printer -U someguest -t "Anon Job.txt" >/dev/null
printf 'Known user job\n' | client lp -h "$SERVER:631" -d Paperless_Printer -U vprint -t "../Known/User" >/dev/null
client lp -h "$SERVER:631" -d Paperless_Printer -U someguest -t "Colour Page" >/dev/null <<'PS'
%!PS-Adobe-3.0
%%Title: (stdin)
1 0 0 setrgbcolor 72 72 200 200 rectfill
0 0 1 setrgbcolor 300 300 200 200 rectfill
showpage
PS

outputs() { in_server find /mnt/output -maxdepth 1 -type f -name '*.pdf' -printf '%f\n' | sort; }
for _ in $(seq 1 60); do
  [[ $(outputs | wc -l) -ge 3 ]] && break
  sleep 1
done
files=()
while IFS= read -r f; do files+=("$f"); done < <(outputs)
printf '  files: %s\n' "${files[@]:-<none>}"
check "three PDFs were produced" test "${#files[@]}" -eq 3
check "filenames use the job title + job id" bash -c "printf '%s\n' \"\$@\" | grep -qx 'Anon Job-job_[0-9]*.pdf'" _ "${files[@]}"
check "path characters in titles are neutralised" bash -c "printf '%s\n' \"\$@\" | grep -qx '_Known_User-job_[0-9]*.pdf'" _ "${files[@]}"
check "no partial or hidden files left behind" bash -c "[[ -z \$(docker exec '$SERVER' find /mnt/output -name '.*' -type f) ]]"
check "staging directory is empty" bash -c "[[ -z \$(docker exec '$SERVER' find /var/spool/vprint -type f) ]]"
for f in "${files[@]}"; do
  check "$f is a PDF" bash -c "docker exec '$SERVER' head -c 5 '/mnt/output/$f' | grep -q '%PDF-'"
  check "$f owned by PUID:PGID with UMASK applied" \
    test "$(in_server stat -c '%u:%g %a' "/mnt/output/$f")" = "1234:2345 640"
done
colour=$(printf '%s\n' "${files[@]}" | grep '^Colour Page' || true)
if [[ -n $colour ]]; then
  # inkcov prints C M Y K coverage per page; a colour page has non-zero C/M/Y.
  check "colour input stays in colour" bash -c \
    "docker exec '$SERVER' gs -q -o - -sDEVICE=inkcov '/mnt/output/$colour' | awk '{ exit !((\$1+\$2+\$3) > 0) }'"
else
  fail "colour job output missing"
fi

section "admin security"
check "plain HTTP admin with valid creds is refused (426)" test "$(curl_code -u "admin:$ADMIN_PASSWORD" "http://$SERVER:631/admin/")" = 426
check "HTTPS admin without creds is refused (401)" test "$(curl_code -k "https://$SERVER:631/admin/")" = 401
check "old default print/print is refused (401)" test "$(curl_code -k -u print:print "https://$SERVER:631/admin/")" = 401
check "HTTPS admin with configured creds works (200)" test "$(curl_code -k -u "admin:$ADMIN_PASSWORD" "https://$SERVER:631/admin/")" = 200
check "LAN host names are accepted for printing (200)" test "$(curl_code -H 'Host: 192.168.1.50:631' "http://$SERVER:631/printers/")" = 200
check "unauthenticated lpadmin is rejected" bash -c "! docker run --rm --network '$NET' --entrypoint '' '$IMAGE' lpadmin -h '$SERVER:631' -U nobody -p Evil -E -v file:/dev/null </dev/null >/dev/null 2>&1"
check "no password material in image history" bash -c "! docker history --no-trunc '$IMAGE' | grep -qiE 'passwd|\\\$1\\\$|\\\$6\\\$'"

section "lifecycle"
start=$(date +%s)
docker stop -t 20 "$SERVER" >/dev/null
check "docker stop is graceful (<10s)" test $(($(date +%s) - start)) -lt 10
check "exit code is 0 after stop" test "$(docker inspect -f '{{.State.ExitCode}}' "$SERVER")" = 0

docker run -d --name "$SERVER-bad" -e PRINTER_ID="has space" "$IMAGE" >/dev/null
sleep 3
check "invalid config fails fast with non-zero exit" test "$(docker inspect -f '{{.State.Status}}:{{.State.ExitCode}}' "$SERVER-bad")" = "exited:64"
check "invalid config explains the problem" bash -c "docker logs '$SERVER-bad' 2>&1 | grep -q 'PRINTER_ID must be'"

docker run -d --name "$SERVER-sup" ${SERVER_ARGS[@]+"${SERVER_ARGS[@]}"} -e CUPS_ADMIN_PASSWORD=x "$IMAGE" >/dev/null
check "supervision test container healthy" wait_healthy "$SERVER-sup"
docker exec "$SERVER-sup" sh -c 'kill "$(cat /run/vprint/avahi.pid)"'
sleep 3
check "container exits when a supervised process dies" test "$(docker inspect -f '{{.State.Status}}' "$SERVER-sup")" = exited

echo
if ((failures)); then
  echo "smoke test: $failures check(s) failed"
  exit 1
fi
echo "smoke test: all checks passed"
