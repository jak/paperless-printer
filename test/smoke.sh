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
  docker rm -f "$SERVER" "$SERVER-bad" "$SERVER-sup" "$SERVER-sup2" "$SERVER-stuck" "$SERVER-tz" >/dev/null 2>&1 || true
  docker volume rm -f "$VOL" "$VOL-ro" "$VOL-shared" "$VOL-multi" "$VOL-spool" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  [[ -z ${SECRET_FILE:-} ]] || rm -f "$SECRET_FILE" "$SECRET_FILE.cfg" "$SECRET_FILE.share"
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
check "Avahi does not expand wildcards such as %h in the printer name" \
  bash -c "! docker exec '$SERVER' grep -q replace-wildcards /etc/avahi/services/vprint.service"
check "PPD default paper size follows PAPER_SIZE" \
  bash -c "docker exec '$SERVER' grep -q '^\*DefaultPageSize: Letter' /etc/cups/ppd/Paperless_Printer.ppd"
check "printer UUID is derived (not the old static one)" \
  bash -c "! docker exec '$SERVER' grep -q b5105127 /etc/cups/printers.conf"
in_server cupsreject Paperless_Printer
check "healthcheck fails while the queue rejects jobs" bash -c "! docker exec '$SERVER' vprint-healthcheck >/dev/null 2>&1"
in_server cupsaccept Paperless_Printer
check "healthcheck passes again once the queue accepts jobs" docker exec "$SERVER" vprint-healthcheck
in_server cupsdisable Paperless_Printer
check "healthcheck fails while the queue is disabled" bash -c "! docker exec '$SERVER' vprint-healthcheck >/dev/null 2>&1"
in_server cupsenable Paperless_Printer
check "healthcheck passes again once the queue is enabled" docker exec "$SERVER" vprint-healthcheck

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
# Staging is writable by every user in the container: a non-root process planting symlinks must
# not get root to log or publish files it can't read itself.
docker exec -u 1000:1000 "$SERVER" sh -c 'cd /var/spool/vprint && ln -s /etc/shadow leak.failed &&
  ln -s /etc/shadow Leak-job_900.pdf && : >Leak-job_900.pdf.done'
for _ in $(seq 1 15); do
  docker exec "$SERVER" sh -c 'ls -A /var/spool/vprint | grep -qi leak' || break
  sleep 1
done
# Markers forged by another user must not make root publish a PDF still being written, or
# delete one: only cups-pdf's (root's) markers count.
docker exec "$SERVER" sh -c 'echo partial >/var/spool/vprint/Victim-job_950.pdf'
docker exec -u 1000:1000 "$SERVER" sh -c 'cd /var/spool/vprint && : >Victim-job_950.pdf.failed && : >Victim-job_950.pdf.done'
sleep 3
check "forged markers neither publish nor delete another job's PDF" bash -c \
  "docker exec '$SERVER' test -f /var/spool/vprint/Victim-job_950.pdf && ! docker exec '$SERVER' sh -c 'ls /mnt/output | grep -q Victim' && ! docker logs '$SERVER' 2>&1 | grep -q 'conversion failed for job 950'"
docker exec "$SERVER" rm -f /var/spool/vprint/Victim-job_950.pdf
check "symlinks planted in staging are not followed" bash -c \
  "! docker logs '$SERVER' 2>&1 | grep -q 'admin:\\\$' && ! docker exec '$SERVER' grep -rqs 'admin:' /mnt/output && ! docker exec '$SERVER' sh -c 'ls -A /var/spool/vprint | grep -qi leak'"
# Something other than a file inside a claim directory (e.g. swapped in while the claim waited
# for cupsd) is removed once and logged once, not retried and logged every second.
docker exec "$SERVER" sh -c 'd=/var/spool/vprint/.vprint-claim.smoketest && mkdir -m 0700 $d &&
  mkdir "$d/Odd-job_901.pdf" && : >"$d/Odd-job_901.pdf/x"'
sleep 4
check "a non-file in a claim directory is removed and logged once" bash -c \
  "! docker exec '$SERVER' test -e /var/spool/vprint/.vprint-claim.smoketest && [[ \$(docker logs '$SERVER' 2>&1 | grep -c 'not a regular file: Odd-job_901') == 1 ]]"
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
check "a mounted output volume raises no warning" bash -c "! docker logs '$SERVER' 2>&1 | grep -q 'not on a mounted volume'"
check "TLS certificate is generated per container" bash -c "docker exec '$SERVER' sh -c 'ls /var/spool/cups-tls/*.crt' >/dev/null"

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
  # Bounded: a config that is wrongly accepted keeps running, and must fail the check, not hang.
  for _ in $(seq 1 30); do
    [[ $(docker inspect -f '{{.State.Running}}' "$SERVER-bad") == false ]] && break
    sleep 1
  done
  docker kill "$SERVER-bad" >/dev/null 2>&1 || true # still running: exit code won't be 64
  # shellcheck disable=SC2016 # expanded by the inner bash
  check "rejects $desc (exit 64 + message)" bash -c \
    '[[ $(docker inspect -f "{{.State.ExitCode}}" "$1") == 64 ]] && docker logs "$1" 2>&1 | grep -qF -- "$2"' _ "$SERVER-bad" "$msg"
}
invalid_config "PRINTER_ID with a space" "PRINTER_ID must be" -e PRINTER_ID="has space"
invalid_config "PRINTER_NAME over 63 bytes" "at most 63 bytes" -e PRINTER_NAME="$(printf 'N%.0s' $(seq 1 64))"
invalid_config "'#' in PRINTER_NAME" "must not contain '#'" -e PRINTER_NAME="Room #2"
invalid_config "regex-like PAPER_SIZE" "PAPER_SIZE 'A.' is not supported" -e PAPER_SIZE="A."
invalid_config "empty TZ" "is not a known time zone" -e TZ=
invalid_config "a zoneinfo table as TZ" "is not a known time zone" -e TZ=zone.tab
for tz in :Europe/London EST5EDT,M3.2.0,M11.1.0; do
  docker run -d --name "$SERVER-tz" -e CUPS_ADMIN_PASSWORD=x -e TZ="$tz" "$IMAGE" >/dev/null
  sleep 4
  check "accepts TZ=$tz" bash -c "docker logs '$SERVER-tz' 2>&1 | grep -q '^vprint: printer'"
  docker rm -f "$SERVER-tz" >/dev/null
done
invalid_config "OUTPUT_DIR=/" "OUTPUT_DIR must not be" -e OUTPUT_DIR=/
invalid_config "OUTPUT_DIR escaping via .." "OUTPUT_DIR must not be" -e OUTPUT_DIR=/mnt/../etc/x
invalid_config "an existing system account as admin" "is an existing system account" -e CUPS_ADMIN_USER=nobody
invalid_config "an existing group name as admin" "is an existing system account or group" -e CUPS_ADMIN_USER=staff
invalid_config "an empty CUPS_SERVER_ALIAS" "CUPS_SERVER_ALIAS must not be empty" -e CUPS_SERVER_ALIAS=
invalid_config "a UMASK that hides PDFs from their owner" "would make the PDFs unreadable" -e UMASK=0777
invalid_config "a PUID beyond the 32-bit range" "at most 4294967294" -e PUID=99999999999999999999
invalid_config "a C1 control character in PRINTER_NAME" "without control characters" -e PRINTER_NAME="$(printf 'A\302\205B')"
invalid_config "an empty admin password file" "points to an empty file" -e CUPS_ADMIN_PASSWORD_FILE=/dev/null
invalid_config "a multi-line admin password" "must be a single line" -e CUPS_ADMIN_PASSWORD="$(printf 'one\nroot:two')"
invalid_config "ADVERTISED_HOST with a port" "is not a valid IPv6 address" -e ADVERTISED_HOST=beef:631
invalid_config "OUTPUT_DIR=/tmp" "OUTPUT_DIR must not be" -e OUTPUT_DIR=/tmp
invalid_config "ADVERTISED_HOST with a space" "is not a host name or IP" -e ADVERTISED_HOST="bad host"
# Run from /etc so a glob like '*.conf' would match files if the list were word-split unquoted.
docker run --rm -w /etc -e CUPS_ADMIN_PASSWORD=x -e ADVERTISED_HOST=fd00::12 \
  -e CUPS_ALLOW_FROM="$(printf '@LOCAL @IF(eth0)\n[fd00::]/8\n*.conf')" --entrypoint bash "$IMAGE" -c \
  'vprint-entrypoint >/dev/null 2>&1 & for _ in $(seq 1 20); do [ -s /etc/avahi/services/vprint.service ] && [ -s /etc/cups/cupsd.conf ] && break; sleep 0.5; done; sleep 1
   cupsd -t >/dev/null 2>&1 && echo CUPSD_OK; grep -h "Allow\|adminurl" /etc/cups/cupsd.conf /etc/avahi/services/vprint.service' >"$SECRET_FILE.cfg" 2>&1 || true
check "allow-list accepts @IF(name), [IPv6] and one entry per line; cupsd accepts the result" bash -c \
  "grep -q CUPSD_OK '$SECRET_FILE.cfg' && grep -qxF '  Allow @IF(eth0)' '$SECRET_FILE.cfg' && grep -qxF '  Allow [fd00::]/8' '$SECRET_FILE.cfg'"
check "allow-list entries are not glob-expanded" grep -qx '  Allow \*\.conf' "$SECRET_FILE.cfg"
check "IPv6 ADVERTISED_HOST is bracketed in the admin URL" grep -qF 'adminurl=https://[fd00::12]:631/' "$SECRET_FILE.cfg"

section "output directory handling"
# A share where root can't set owners (SMB/CIFS, root-squashed NFS): simulated by running the
# mover without CAP_CHOWN. The PDF must still be delivered, with one warning.
docker run --rm --entrypoint bash "$IMAGE" -c '
  mkdir -p /run/vprint /var/spool/vprint /mnt/output
  printf "OUTPUT_DIR=/mnt/output\nPUID=1000\nPGID=1000\nUMASK=0022\nVPRINT_STAGING_DIR=/var/spool/vprint\nOUTPUT_LABEL=2\n" >/run/vprint/env
  echo pdf >/var/spool/vprint/Plain.pdf && : >/var/spool/vprint/Plain.pdf.done
  VPRINT_SCHEDULER_WAIT=0 timeout 5 setpriv --bounding-set=-chown --inh-caps=-chown vprint-mover
  stat -c "%n %a" /mnt/output/*' >"$SECRET_FILE.share" 2>&1 || true
check "files are still delivered, readable, where owners can't be set (with a warning)" bash -c \
  "grep -qx '/mnt/output/Plain.pdf 644' '$SECRET_FILE.share' && grep -q 'WARNING: cannot set owner' '$SECRET_FILE.share'"
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
# Run like the compose examples: read-only root, tmpfs /run and /tmp, /var/spool on a volume.
docker volume create "$VOL-ro" >/dev/null
docker volume create "$VOL-spool" >/dev/null
docker run -d --name "$SERVER-stuck" -e CUPS_ADMIN_PASSWORD=x -e VPRINT_STUCK_SECONDS=3 \
  --read-only --tmpfs /run --tmpfs /tmp -v "$VOL-spool:/var/spool" \
  -v "$VOL-ro:/mnt/output:ro" "$IMAGE" >/dev/null
check "container with read-only output healthy at start" wait_healthy "$SERVER-stuck"
printf 'first\n' | docker exec -i "$SERVER-stuck" lp -t "Stuck Job" >/dev/null
sleep 8
check "unwritable output dir makes the healthcheck fail" bash -c \
  "! docker exec '$SERVER-stuck' vprint-healthcheck >/dev/null 2>&1 && docker exec '$SERVER-stuck' vprint-healthcheck 2>&1 | grep -q 'not being delivered: cannot write to /mnt/output'"
check "unwritable output dir is logged" bash -c "docker logs '$SERVER-stuck' 2>&1 | grep -q 'cannot write to /mnt/output'"
# Restart with cupsd's job history and job.cache gone (as if lost): job ids start again at 1, so a new job
# with the same title gets the same cups-pdf file name. The queued PDF must survive the restart,
# keep its title, and not be overwritten by the new job.
tls_cert() { docker exec "$SERVER-stuck" sh -c 'lpstat -E -h localhost:631 -r >/dev/null; cat /var/spool/cups-tls/*.crt' | md5sum; }
cert_before=$(tls_cert)
# (Deleted while stopped: cupsd writes its job history back on shutdown.)
docker stop -t 5 "$SERVER-stuck" >/dev/null
# Also leave an incomplete PDF from an interrupted conversion (no .done marker, long unchanged).
docker run --rm -v "$VOL-spool:/var/spool" --entrypoint '' "$IMAGE" sh -c \
  'rm -f /var/spool/cups/c* /var/spool/cups/d* /var/spool/cups-cache/job.cache && echo partial >/var/spool/vprint/Orphan-job_99.pdf && touch -d "-2 hours" /var/spool/vprint/Orphan-job_99.pdf'
docker start "$SERVER-stuck" >/dev/null
for _ in $(seq 1 30); do
  (($(docker logs "$SERVER-stuck" 2>&1 | grep -c 'vprint-mover: watching') >= 2)) && break
  sleep 1
done
printf 'second\n' | docker exec -i "$SERVER-stuck" lp -t "Stuck Job" >/dev/null
for _ in $(seq 1 20); do
  (($(docker exec "$SERVER-stuck" find /var/spool/vprint -path '*/.vprint-claim.*/*' -type f | wc -l) >= 2)) && break
  sleep 1
done
claimed() { docker exec "$SERVER-stuck" find /var/spool/vprint -path '*/.vprint-claim.*/*' -type f "$@"; }
check "the TLS certificate survives a restart" test "$(tls_cert)" = "$cert_before"
check "an interrupted conversion's leftover is removed from staging" bash -c \
  "! docker exec '$SERVER-stuck' test -e /var/spool/vprint/Orphan-job_99.pdf && docker logs '$SERVER-stuck' 2>&1 | grep -q 'removing an incomplete PDF.*Orphan-job_99'"
check "queued PDF survives a restart and keeps its title" \
  test "$(claimed -printf '%f\n' | grep -cx 'Stuck Job-job_1.pdf')" = 2
check "a reused job id does not overwrite the queued PDF" \
  test "$(claimed -exec md5sum {} + | cut -c1-32 | sort -u | wc -l | tr -d ' ')" = 2
# A finished PDF whose completion marker never got written (job 1 completed) is published by
# the start-up sweep, not deleted as an interrupted conversion.
docker exec "$SERVER-stuck" sh -c 'echo done >/var/spool/vprint/Late-job_1.pdf && touch -d "-2 hours" /var/spool/vprint/Late-job_1.pdf'
# A plain restart keeps job.cache (CacheDir is on the spool), so numbering continues.
docker restart -t 5 "$SERVER-stuck" >/dev/null
for _ in $(seq 1 30); do
  (($(docker logs "$SERVER-stuck" 2>&1 | grep -c 'vprint-mover: watching') >= 3)) && break
  sleep 1
done
printf 'third\n' | docker exec -i "$SERVER-stuck" lp -t "After Restart" >/dev/null
for _ in $(seq 1 20); do
  [[ -n $(claimed -name 'After Restart-job_*') ]] && break
  sleep 1
done
check "a finished PDF missing its completion marker is published, not deleted" bash -c \
  "docker logs '$SERVER-stuck' 2>&1 | grep -q 'publishing a finished PDF whose completion marker is missing: Late-job_1' && ! docker exec '$SERVER-stuck' test -e /var/spool/vprint/Late-job_1.pdf"
check "job numbers continue across a restart" test "$(claimed -name 'After Restart-job_*' -printf '%f')" = "After Restart-job_2.pdf"

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
printf 'dot\n' | docker exec -i "$SERVER-sup" lp -t "example.com" >/dev/null
printf 'ext\n' | docker exec -i "$SERVER-sup" lp -t "Quarterly Report.DOCX" >/dev/null
printf 'trim\n' | docker exec -i "$SERVER-sup" lp -t "Notes .txt" >/dev/null
for _ in $(seq 1 30); do
  docker exec "$SERVER-sup" test -e /mnt/output/example.com.pdf -a -e "/mnt/output/Quarterly Report.pdf" -a -e /mnt/output/Notes.pdf && break
  sleep 1
done
check "only known document extensions are dropped from titles, without a trailing space" \
  docker exec "$SERVER-sup" test -e /mnt/output/example.com.pdf -a -e "/mnt/output/Quarterly Report.pdf" -a -e /mnt/output/Notes.pdf
# A folder already holding NAME and NAME-1..NAME-99: the next one gets a time-based suffix.
docker exec "$SERVER-sup" bash -c 'cd /mnt/output && touch Busy.pdf Busy-{1..99}.pdf'
printf 'busy\n' | docker exec -i "$SERVER-sup" lp -t "Busy" >/dev/null
for _ in $(seq 1 30); do
  [[ -n $(docker exec "$SERVER-sup" find /mnt/output -regex '.*/Busy-[0-9]+-[0-9]+-[0-9]+\.pdf') ]] && break
  sleep 1
done
check "after 99 clashes a time-based suffix is used" \
  test -n "$(docker exec "$SERVER-sup" find /mnt/output -regex '.*/Busy-[0-9]+-[0-9]+-[0-9]+\.pdf')"
docker exec "$SERVER-sup" sh -c 'rm -f /mnt/output/Busy*.pdf'
# Titles cupsd accepts but ipptool's own checks reject (over 255 bytes, or with a newline)
# must keep their title rather than become "untitled".
printf 'long\n' | docker exec -i "$SERVER-sup" lp -t "$(printf 'Long%.0s' $(seq 1 70))" >/dev/null
printf 'nl\n' | docker exec -i "$SERVER-sup" lp -t "$(printf 'Two\nLines')" >/dev/null
for _ in $(seq 1 30); do
  docker exec "$SERVER-sup" test -e "/mnt/output/Two Lines.pdf" && break
  sleep 1
done
check "titles over 255 bytes or with a newline keep their title" bash -c \
  "docker exec '$SERVER-sup' test -e '/mnt/output/Two Lines.pdf' && docker exec '$SERVER-sup' sh -c 'ls /mnt/output | grep -q ^LongLongLong' && ! docker exec '$SERVER-sup' sh -c 'ls /mnt/output | grep -q ^untitled'"
docker exec "$SERVER-sup" sh -c 'rm -f /mnt/output/Long*.pdf "/mnt/output/Two Lines.pdf"'
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
