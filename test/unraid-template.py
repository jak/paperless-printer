#!/usr/bin/env python3
"""Check the Unraid template, or print the `docker run` arguments Unraid would build from it.

Usage: test/unraid-template.py check
       test/unraid-template.py args NAME   # one argument per line, for test/unraid.sh

`args` follows Unraid's dockerMan: TZ and HOST_* from the server, one -e/-v/-p per Config
(the selected value, else the first choice of the Default list), then ExtraParams. Host paths
under /mnt/user/appdata/ become named volumes prefixed with NAME, the network becomes NAME, ports
are not published (as on br0), and the image is left to the caller.
"""
import os
import re
import shlex
import sys
import xml.etree.ElementTree as ET

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEMPLATE = "templates/virtual-cups-printer.xml"
RAW = "https://raw.githubusercontent.com/jak/virtual-cups-printer/master/"
# Set in the template but deliberately not given an image default.
NO_IMAGE_DEFAULT = {"CUPS_ADMIN_PASSWORD"}


def load(path):
    return ET.parse(os.path.join(ROOT, path)).getroot()


def value(cfg):
    """What the Unraid UI starts with: the element text, else the first Default choice."""
    if cfg.text is not None and cfg.text.strip():
        return cfg.text
    return cfg.get("Default", "").split("|")[0]


def image_env():
    """Names set by the Dockerfile's ENV instruction."""
    text = open(os.path.join(ROOT, "Dockerfile")).read().replace("\\\n", " ")
    names = set()
    for line in text.splitlines():
        if line.startswith("ENV "):
            names.update(re.findall(r"([A-Z_][A-Z0-9_]*)=", line))
    return names


def check():
    errors = []
    root = load(TEMPLATE)
    req = lambda tag: (root.findtext(tag) or "").strip()
    for tag in ("Name", "Repository", "Overview", "Category", "Support", "Project", "TemplateURL", "Icon", "WebUI"):
        if not req(tag):
            errors.append(f"<{tag}> is missing or empty")
    if req("TemplateURL") != RAW + TEMPLATE:
        errors.append(f"<TemplateURL> must be {RAW + TEMPLATE}")
    icon = req("Icon")
    if not icon.startswith(RAW) or not os.path.isfile(os.path.join(ROOT, icon[len(RAW):])):
        errors.append(f"<Icon> {icon} is not a file in this repository")
    if not re.fullmatch(r"ghcr\.io/jak/virtual-cups-printer:\d+", req("Repository")):
        errors.append("<Repository> should follow a major-version tag, e.g. ghcr.io/jak/virtual-cups-printer:2")
    known = image_env() | NO_IMAGE_DEFAULT
    targets = set()
    for cfg in root.iter("Config"):
        kind, target = cfg.get("Type"), cfg.get("Target")
        if not target or target in targets:
            errors.append(f"Config {cfg.get('Name')!r}: missing or duplicate Target {target!r}")
        targets.add(target)
        if kind == "Variable" and target not in known:
            errors.append(f"Config {cfg.get('Name')!r}: {target} is not an environment variable the image uses")
        if kind not in ("Variable", "Path", "Port"):
            errors.append(f"Config {cfg.get('Name')!r}: unexpected Type {kind!r}")
        if "|" in cfg.get("Default", "") and value(cfg) not in cfg.get("Default").split("|"):
            errors.append(f"Config {cfg.get('Name')!r}: value {value(cfg)!r} is not one of its choices")
    profile = load("ca_profile.xml")
    if not (profile.findtext("Profile") or "").strip():
        errors.append("ca_profile.xml: <Profile> is empty")
    for e in errors:
        print(e, file=sys.stderr)
    return 1 if errors else 0


def args(name):
    root = load(TEMPLATE)
    out = ["--name", name, "--network", name,
           "-e", "TZ=Europe/London", "-e", "HOST_OS=Unraid", "-e", f"HOST_HOSTNAME=tower", "-e", f"HOST_CONTAINERNAME={name}"]
    for cfg in root.iter("Config"):
        kind, target, val = cfg.get("Type"), cfg.get("Target"), value(cfg)
        if kind == "Variable":
            out += ["-e", f"{target}={val}"]
        elif kind == "Path":
            prefix = "/mnt/user/appdata/virtual-cups-printer/"
            assert val.startswith(prefix), val
            volume = name + "-" + val[len(prefix):].replace("/", "-")
            out += ["-v", f"{volume}:{target}:{cfg.get('Mode', 'rw')}"]
        # Ports: not published, as on br0 (and so tests can't clash on the host's port 631).
    out += shlex.split(root.findtext("ExtraParams") or "")
    print("\n".join(out))
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["check"]:
        sys.exit(check())
    if len(sys.argv) == 3 and sys.argv[1] == "args":
        sys.exit(args(sys.argv[2]))
    sys.exit(__doc__)
