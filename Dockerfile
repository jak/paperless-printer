# syntax=docker/dockerfile:1
FROM debian:trixie-slim@sha256:8aa5a7bf5a1955bddbe7d74fcdd0b91ab30e74362a8b73af672b0481b35b44a0

ARG VERSION=dev
ARG REVISION=unknown

LABEL org.opencontainers.image.title="virtual-cups-printer" \
      org.opencontainers.image.description="Network (AirPrint/IPP) printer that saves every job as a PDF, e.g. into a paperless-ngx consume directory" \
      org.opencontainers.image.source="https://github.com/jak/virtual-cups-printer" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}"

# The base is pinned by digest for a reproducible starting point; `upgrade` applies current
# Debian security updates on every build (incl. the weekly release rebuild). Package versions
# are deliberately unpinned (DL3008) so security updates are picked up.
# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get -y upgrade \
 && apt-get install -y --no-install-recommends \
      avahi-daemon \
      cups \
      gettext-base \
      printer-driver-cups-pdf \
      tini \
      tzdata \
 && rm -rf /var/lib/apt/lists/* \
 # ssl-cert (a cups-daemon dependency) generates a snakeoil key pair at install time, which
 # would be identical in every copy of this image. CUPS generates its own per-container cert.
 && rm -f /etc/ssl/private/ssl-cert-snakeoil.key /etc/ssl/certs/ssl-cert-snakeoil.pem \
 # Avahi: no D-Bus in the container; publish only our static service file.
 && sed -i 's/^#\?enable-dbus=.*/enable-dbus=no/' /etc/avahi/avahi-daemon.conf \
 && rm -f /etc/avahi/services/*.service \
 # CUPS: all logs to the container's stderr so they show up in `docker logs`.
 && sed -i -E 's#^(AccessLog|ErrorLog|PageLog) .*#\1 stderr#' /etc/cups/cups-files.conf \
 && echo 'CacheDir /run/vprint/cache' >>/etc/cups/cups-files.conf \
 # Account used by cups-pdf for anonymous jobs. Output ownership comes from PUID/PGID.
 && groupadd --gid 1000 vprint \
 && useradd --uid 1000 --gid vprint --no-create-home --home-dir /nonexistent \
      --shell /usr/sbin/nologin vprint \
 # Runtime-written state lives under /run so the root filesystem can be read-only:
 # keep pristine copies in /usr/local/share/vprint/dist and symlink /etc to /run/vprint.
 && dist=/usr/local/share/vprint/dist \
 && mkdir -p "$dist/accounts/etc" \
 && mv /etc/cups /etc/avahi "$dist/" \
 && ln -s /run/vprint/etc/cups /etc/cups \
 && ln -s /run/vprint/etc/avahi /etc/avahi \
 && rm -f /etc/papersize && ln -s /run/vprint/etc/papersize /etc/papersize \
 && cp /etc/login.defs "$dist/accounts/etc/" \
 && for f in passwd group shadow gshadow; do \
      mv "/etc/$f" "$dist/accounts/etc/$f" && ln -s "/run/vprint/accounts/etc/$f" "/etc/$f"; \
    done \
 && rm -f /etc/passwd- /etc/group- /etc/shadow- /etc/gshadow-

COPY --chmod=0755 rootfs/usr/local/bin/ /usr/local/bin/
COPY rootfs/etc/vprint/ /etc/vprint/

ENV PRINTER_ID=Paperless_Printer \
    PRINTER_NAME="Paperless Printer" \
    PRINTER_LOCATION="" \
    PRINTER_UUID="" \
    PAPER_SIZE=A4 \
    TZ=UTC \
    OUTPUT_DIR=/mnt/output \
    OUTPUT_LABEL=2 \
    PUID=1000 \
    PGID=1000 \
    UMASK=0022 \
    CUPS_ADMIN_USER=admin \
    CUPS_LOG_LEVEL=warn \
    CUPS_ALLOW_FROM=all \
    CUPS_SERVER_ALIAS="*" \
    CUPS_WEB_INTERFACE=yes \
    AVAHI_ENABLED=yes \
    ADVERTISED_HOST=""

EXPOSE 631
VOLUME ["/mnt/output"]

HEALTHCHECK --interval=30s --timeout=10s --start-period=20s --retries=3 \
  CMD ["/usr/local/bin/vprint-healthcheck"]

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/vprint-entrypoint"]
