# 1. Stay on CUPS 2.x with the cups-pdf PPD driver for now

- Status: accepted
- Date: 2026-11-25
- Issue: #24

## Context

CUPS 2.4 logs on every start:

```
Printer drivers are deprecated and will stop working in a future version of CUPS.
See https://github.com/OpenPrinting/cups/issues/103
```

This project uses a classic PPD (`CUPS-PDF_noopt.ppd`) and the `cups-pdf` backend.
CUPS 3.x drops PPD drivers in favour of IPP Everywhere / Printer Applications (PAPPL).

Debian 13 (trixie), our base, ships CUPS 2.4.10 and will keep it for the life of the release,
with security support to about mid-2028 and LTS beyond that.

## Options

1. **Stay on CUPS 2.4 + cups-pdf.** It works, the smoke test covers it, and the AirPrint
   advertisement is known to work with iOS colour printing.
2. **Replace it with a Printer Application:** a small PAPPL-based app, or `ippeveprinter` with a
   PDF-saving `-c` command. This is native IPP Everywhere with correct DNS-SD records generated
   automatically (no hand-written Avahi file) and no deprecation. But it's a rewrite of the core,
   `ippeveprinter` is a test tool rather than a production server, and there's no ready-made
   PAPPL "save as PDF" application in Debian.

## Decision

Option 1, for as long as the base distribution ships CUPS 2.x. The deprecation warning is
expected and harmless.

## Consequences

- Revisit when Debian's next release (forky) is frozen, or if a CUPS 2.x update actually
  disables PPD drivers. Whichever happens first triggers a spike on option 2.
- The smoke test is the safety net for any future migration: it tests behaviour over IPP
  (PDF output, naming, permissions, colour), not the implementation.
