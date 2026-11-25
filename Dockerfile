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

# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      avahi-daemon \
      cups \
      gettext-base \
      printer-driver-cups-pdf \
      tini \
      tzdata \
 && rm -rf /var/lib/apt/lists/* \
 # Avahi: no D-Bus in the container; publish only our static service file.
 && sed -i 's/^#\?enable-dbus=.*/enable-dbus=no/' /etc/avahi/avahi-daemon.conf \
 && rm -f /etc/avahi/services/*.service \
 # CUPS: all logs to the container's stderr so they show up in `docker logs`.
 && sed -i -E 's#^(AccessLog|ErrorLog|PageLog) .*#\1 stderr#' /etc/cups/cups-files.conf \
 # Output owner. UID/GID are remapped at start from PUID/PGID.
 && groupadd --gid 1000 vprint \
 && useradd --uid 1000 --gid vprint --no-create-home --home-dir /nonexistent \
      --shell /usr/sbin/nologin vprint

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
