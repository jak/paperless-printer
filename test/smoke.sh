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
  docker rm -f "$SERVER" "$SERVER-bad" "$SERVER-sup" "$SERVER-sup2" "$SERVER-stuck" >/dev/null 2>&1 || true
  docker volume rm -f "$VOL" "$VOL-ro" "$VOL-shared" "$VOL-multi" >/dev/null 2>&1 || true
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
  local name=$1 status
  for _ in $(seq 1 60); do
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
  -e PRINTER_NAME="Smoke & <Test> Printer" -e PRINTER_LOCATION='Desk "B"' -e CUPS_ALLOW_FROM=@LOCAL \
  -e PUID=1234 -e PGID=2345 -e UMASK=0027 \
  -e PAPER_SIZE=Letter -e TZ=Europe/London \
  -v "$VOL:/mnt/output" "$IMAGE" >/dev/null
check "container becomes healthy" wait_healthy "$SERVER"
check "CUPS logs reach docker logs" bash -c "docker logs '$SERVER' 2>&1 | grep -q 'vprint-mover: watching'"
check "avahi publishes the service" bash -c "docker logs '$SERVER' 2>&1 | grep -q 'successfully established'"
check "avahi service file is valid XML with escaped name" \
  bash -c "svc=\$(docker exec '$SERVER' cat /etc/avahi/services/vprint.service); grep -qF '>Smoke &amp; &lt;Test&gt; Printer<' <<<\"\$svc\" && grep -qF 'note=Desk &quot;B&quot;<' <<<\"\$svc\" && ! grep -q '<lt;' <<<\"\$svc\""
check "PPD default paper size follows PAPER_SIZE" \
  bash -c "docker exec '$SERVER' grep -q '^\*DefaultPageSize: Letter' /etc/cups/ppd/Paperless_Printer.ppd"
check "printer UUID is derived (not the old static one)" \
  bash -c "! docker exec '$SERVER' grep -q b5105127 /etc/cups/printers.conf"
in_server cupsreject Paperless_Printer
check "healthcheck fails while the queue rejects jobs" bash -c "! docker exec '$SERVER' vprint-healthcheck >/dev/null 2>&1"
in_server cupsaccept Paperless_Printer
check "healthcheck passes again once the queue accepts jobs" docker exec "$SERVER" vprint-healthcheck

section "print over the network"
printf 'Hello from the smoke test\n' | client lp -h "$SERVER:631" -d Paperless_Printer -U someguest -t "Anon Job.txt" >/dev/null
printf 'Odd title\n' | client lp -h "$SERVER:631" -d Paperless_Printer -U someguest -t 'Invoice, March "2024"' >/dev/null
printf 'Known user job\n' | client lp -h "$SERVER:631" -d Paperless_Printer -U vprint -t "../Known/User" >/dev/null
client lp -h "$SERVER:631" -d Paperless_Printer -U someguest -t "Colour Page" >/dev/null <<'PS'
%!PS-Adobe-3.0
%%Title: (stdin)
1 0 0 setrgbcolor 72 72 200 200 rectfill
0 0 1 setrgbcolor 300 300 200 200 rectfill
showpage
PS

# A document Ghostscript cannot convert (sent raw so it reaches cups-pdf unfiltered).
printf '%%!PS-Adobe-3.0\nthis_is_not_an_operator\nshowpage\n' |
  client lp -h "$SERVER:631" -d Paperless_Printer -o raw -t "Broken Doc" >/dev/null

outputs() { in_server find /mnt/output -maxdepth 1 -type f -name '*.pdf' -printf '%f\n' | sort; }
for _ in $(seq 1 60); do
  [[ $(outputs | wc -l) -ge 4 ]] && break
  sleep 1
done
# Also wait for the broken job to be fully processed, so the staging checks below see a quiet spool.
for _ in $(seq 1 60); do
  docker logs "$SERVER" 2>&1 | grep -q 'PDF conversion failed for job' && break
  sleep 1
done
files=()
while IFS= read -r f; do files+=("$f"); done < <(outputs)
printf '  files: %s\n' "${files[@]:-<none>}"
check "four PDFs were produced" test "${#files[@]}" -eq 4
check "titles with commas and quotes are kept readable" bash -c "printf '%s\n' \"\$@\" | grep -qx 'Invoice, March _2024_-job_[0-9]*.pdf'" _ "${files[@]}"
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
# shellcheck disable=SC2016 # literal regex
check "no password hashes in image history" bash -c "! docker history --no-trunc '$IMAGE' | grep -qE '[$][156y][$][A-Za-z0-9./]{4,}'"
check "no private keys baked into the image" \
  bash -c "[[ -z \$(docker run --rm --entrypoint '' '$IMAGE' find /etc/ssl/private /usr/local/share/vprint/dist/cups/ssl -type f) ]]"
check "TLS certificate is generated per container" bash -c "docker exec '$SERVER' sh -c 'ls /etc/cups/ssl/*.crt' >/dev/null"

check "failed conversions are reported in the log" \
  bash -c "docker logs '$SERVER' 2>&1 | grep -q 'ERROR: PDF conversion failed for job [0-9]* \"Broken Doc\"'"
check "failed conversions leave no files behind" \
  bash -c "[[ -z \$(docker exec '$SERVER' find /mnt/output /var/spool/vprint -name '*Broken*') ]]"

section "lifecycle"
start=$(date +%s)
docker stop -t 20 "$SERVER" >/dev/null
check "docker stop is graceful (<10s)" test $(($(date +%s) - start)) -lt 10
check "exit code is 0 after stop" test "$(docker inspect -f '{{.State.ExitCode}}' "$SERVER")" = 0

# invalid_config DESCRIPTION EXPECTED_MESSAGE -e VAR=value...
invalid_config() {
  local desc=$1 msg=$2
  shift 2
  docker rm -f "$SERVER-bad" >/dev/null 2>&1 || true
  docker run -d --name "$SERVER-bad" "$@" "$IMAGE" >/dev/null
  docker wait "$SERVER-bad" >/dev/null
  # shellcheck disable=SC2016 # expanded by the inner bash
  check "rejects $desc (exit 64 + message)" bash -c \
    '[[ $(docker inspect -f "{{.State.ExitCode}}" "$1") == 64 ]] && docker logs "$1" 2>&1 | grep -qF -- "$2"' _ "$SERVER-bad" "$msg"
}
invalid_config "PRINTER_ID with a space" "PRINTER_ID must be" -e PRINTER_ID="has space"
invalid_config "PRINTER_NAME over 63 bytes" "at most 63 bytes" -e PRINTER_NAME="$(printf 'N%.0s' $(seq 1 64))"
invalid_config "'#' in PRINTER_NAME" "must not contain '#'" -e PRINTER_NAME="Room #2"
invalid_config "regex-like PAPER_SIZE" "PAPER_SIZE 'A.' is not supported" -e PAPER_SIZE="A."
invalid_config "empty TZ" "is not a known time zone" -e TZ=
invalid_config "OUTPUT_DIR=/" "OUTPUT_DIR must not be" -e OUTPUT_DIR=/
invalid_config "OUTPUT_DIR escaping via .." "OUTPUT_DIR must not be" -e OUTPUT_DIR=/mnt/../etc/x

section "output directory handling"
# An existing, populated directory (e.g. a host consume folder) must not be re-owned.
docker volume create "$VOL-shared" >/dev/null
docker run --rm -v "$VOL-shared:/d" --entrypoint '' "$IMAGE" sh -c 'touch /d/scanner-file && chown 4321:4321 /d /d/scanner-file'
# No admin password configured (the default): must start and log a generated one.
docker run -d --name "$SERVER-stuck" -e PUID=1234 -v "$VOL-shared:/mnt/output" "$IMAGE" >/dev/null
check "container with shared output dir healthy" wait_healthy "$SERVER-stuck"
check "no admin password set: one is generated and logged" bash -c \
  "docker logs '$SERVER-stuck' 2>&1 | grep -A1 'generated a one-off admin password' | grep -Eq '[0-9a-f]{24}'"
check "existing populated output dir keeps its owner" test "$(docker exec "$SERVER-stuck" stat -c %u /mnt/output)" = 4321
docker rm -f "$SERVER-stuck" >/dev/null

# A read-only output volume: jobs can't be published, so health must go bad (not silently pile up).
docker volume create "$VOL-ro" >/dev/null
docker run -d --name "$SERVER-stuck" -e CUPS_ADMIN_PASSWORD=x -e VPRINT_STUCK_SECONDS=3 \
  -v "$VOL-ro:/mnt/output:ro" "$IMAGE" >/dev/null
check "container with read-only output healthy at start" wait_healthy "$SERVER-stuck"
printf 'stuck\n' | docker exec -i "$SERVER-stuck" lp -t "Stuck Job" >/dev/null
sleep 8
check "unwritable output dir makes the healthcheck fail" bash -c \
  "! docker exec '$SERVER-stuck' vprint-healthcheck 2>&1 | grep -q healthy; docker exec '$SERVER-stuck' vprint-healthcheck 2>&1 | grep -q 'cannot be written'"
check "unwritable output dir is logged" bash -c "docker logs '$SERVER-stuck' 2>&1 | grep -q 'cannot write to /mnt/output'"

docker rm -f "$SERVER-stuck" >/dev/null

# Two publishers sharing one output directory. Seed it with another writer's in-flight temporary
# file (fresh) and a crash leftover (stale): start-up must only remove the stale one.
docker volume create "$VOL-multi" >/dev/null
docker run --rm -v "$VOL-multi:/d" --entrypoint '' "$IMAGE" sh -c \
  'touch /d/.vprint-inflight.vprint-partial && touch -d "-1 hour" /d/.vprint-stale.vprint-partial'
for s in sup sup2; do
  docker run -d --name "$SERVER-$s" ${SERVER_ARGS[@]+"${SERVER_ARGS[@]}"} -e CUPS_ADMIN_PASSWORD=x \
    -e OUTPUT_LABEL=0 -e PUID=08 -v "$VOL-multi:/mnt/output" "$IMAGE" >/dev/null
done
check "second container (OUTPUT_LABEL=0) healthy" wait_healthy "$SERVER-sup"
check "third container sharing the output dir healthy" wait_healthy "$SERVER-sup2"
check "start-up removes stale temporary files only" test "$(docker exec "$SERVER-sup" sh -c 'ls -A /mnt/output' | tr '\n' '|')" = ".vprint-inflight.vprint-partial|"
docker exec "$SERVER-sup" rm /mnt/output/.vprint-inflight.vprint-partial
# Both containers publish same-titled jobs at once: every document must survive, de-duplicated.
for i in 1 2 3 4 5; do
  for s in sup sup2; do printf '%s %s\n' "$s" "$i" | docker exec -i "$SERVER-$s" lp -t "Race" >/dev/null & done
done
wait
for _ in $(seq 1 60); do
  (($(docker exec "$SERVER-sup" sh -c 'ls /mnt/output | wc -l') >= 10)) && break
  sleep 1
done
check "concurrent publishers sharing a directory lose no documents" \
  test "$(docker exec "$SERVER-sup" sh -c 'md5sum /mnt/output/Race*.pdf | cut -d" " -f1 | sort -u | wc -l; ls -A /mnt/output | grep -c partial')" = "$(printf '10\n0')"
docker rm -f "$SERVER-sup2" >/dev/null
docker exec "$SERVER-sup" sh -c 'rm -f /mnt/output/*'
# A directory with the target's name must count as a clash, not as a place to move into.
docker exec "$SERVER-sup" mkdir "/mnt/output/Dir Clash.pdf"
printf 'dir\n' | docker exec -i "$SERVER-sup" lp -t "Dir Clash" >/dev/null
for n in 1 2; do
  printf 'same\n' | docker exec -i "$SERVER-sup" lp -t "Same Name" >/dev/null
  # Wait for job n to be published before sending the next, so the clash is deterministic.
  for _ in $(seq 1 30); do
    (($(docker exec "$SERVER-sup" sh -c 'ls /mnt/output | wc -l') >= n + 2)) && break
    sleep 1
  done
done
check "PUID with a leading zero is read as decimal" test "$(docker exec "$SERVER-sup" stat -c %u "/mnt/output/Same Name.pdf")" = 8
check "OUTPUT_LABEL=0 names by title and de-duplicates clashes" \
  test "$(docker exec "$SERVER-sup" ls /mnt/output | LC_ALL=C sort | tr '\n' '|')" = "Dir Clash-1.pdf|Dir Clash.pdf|Same Name-1.pdf|Same Name.pdf|"
check "a same-named directory is treated as a clash" test -n "$(docker exec "$SERVER-sup" find "/mnt/output/Dir Clash-1.pdf" -type f)"
docker exec "$SERVER-sup" sh -c 'kill "$(cat /run/vprint/avahi.pid)"'
sleep 3
check "container exits when a supervised process dies" test "$(docker inspect -f '{{.State.Status}}' "$SERVER-sup")" = exited

echo
if ((failures)); then
  echo "smoke test: $failures check(s) failed"
  exit 1
fi
echo "smoke test: all checks passed"
