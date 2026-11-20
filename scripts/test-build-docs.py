#!/usr/bin/env python3
"""Checks that each install card of the site shows its own project's platforms.

Two projects declare different Fedora releases, architectures, Ubuntu
releases, setup and install commands; every card must carry the values of the manifest
that declared its package, never those of another project.
"""
import importlib.util
import sys
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / "build-docs.py"
spec = importlib.util.spec_from_file_location("build_docs", SCRIPT)
build_docs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build_docs)


def manifest(name, fedora, arch, codenames, versions, rpm_setup, deb_setup):
    return {
        "project": {"id": name, "name": name.title()},
        "packages": [
            {"name": name, "displayName": name.title(), "category": "main", "requires": None},
        ],
        "platforms": {
            "rpm": {
                "distros": [
                    {"id": "fedora", "name": "Fedora", "versions": fedora, "prefix": "fc", "arch": arch},
                ],
                "repoSetup": rpm_setup,
                "installCmd": f"{name}-rpm-install",
            },
            "deb": {
                "distros": [
                    {"id": "ubuntu", "name": "Ubuntu", "codenames": codenames, "versions": versions},
                ],
                "repoSetup": deb_setup,
                "installCmd": f"{name}-deb-install",
            },
        },
        "docs": [],
    }


def cards_of(html, tab_id, display):
    """The install cards of one tab (RPM or DEB) whose title is *display*."""
    tab = html.split(f'<div id="{tab_id}"', 1)[1].split('<div id="distro-', 1)[0]
    return [c for c in tab.split('<div class="install-card ')[1:] if f"<h4>{display}</h4>" in c]


def check(cond, message):
    if not cond:
        print(f"FAIL: {message}", file=sys.stderr)
        sys.exit(1)


alpha = manifest("alpha", ["41", "42"], "x86_64", ["jammy"], ["22.04"], "alpha-rpm-setup", "alpha-deb-setup")
beta = manifest(
    "beta", ["44", "45"], "x86_64, aarch64", ["resolute"], ["26.04"], "beta-rpm-setup", "beta-deb-setup"
)
html = build_docs.gen_install_tabs([alpha, beta])

for display, own, other in (("Alpha", alpha, beta), ("Beta", beta, alpha)):
    rpm = cards_of(html, "distro-fedora", display)
    deb = cards_of(html, "distro-debian", display)
    check(len(rpm) == 1 and len(deb) == 1, f"{display}: expected one RPM and one DEB card")
    rpm_platform = own["platforms"]["rpm"]
    fedora = rpm_platform["distros"][0]
    for v in fedora["versions"]:
        check(f">fc{v}<" in rpm[0], f"{display}: RPM card lacks fc{v}")
    for v in other["platforms"]["rpm"]["distros"][0]["versions"]:
        check(f">fc{v}<" not in rpm[0], f"{display}: RPM card shows fc{v} of another project")
    supported = f'Fedora {", ".join(fedora["versions"])} ({fedora["arch"]})'
    check(supported in rpm[0], f"{display}: RPM card does not say {supported!r}")
    check(rpm_platform["repoSetup"] in rpm[0], f"{display}: RPM card lacks its own setup")
    check(other["platforms"]["rpm"]["repoSetup"] not in rpm[0], f"{display}: RPM card has another setup")
    check(rpm_platform["installCmd"] in rpm[0], f"{display}: RPM card lacks its own install command")
    check(
        other["platforms"]["rpm"]["installCmd"] not in rpm[0], f"{display}: RPM card has another install command"
    )
    deb_platform = own["platforms"]["deb"]
    for c in deb_platform["distros"][0]["codenames"]:
        check(f">{c}<" in deb[0], f"{display}: DEB card lacks {c}")
    for c in other["platforms"]["deb"]["distros"][0]["codenames"]:
        check(f">{c}<" not in deb[0], f"{display}: DEB card shows {c} of another project")
    check(deb_platform["repoSetup"] in deb[0], f"{display}: DEB card lacks its own setup")
    check(other["platforms"]["deb"]["repoSetup"] not in deb[0], f"{display}: DEB card has another setup")
    check(deb_platform["installCmd"] in deb[0], f"{display}: DEB card lacks its own install command")
    check(
        other["platforms"]["deb"]["installCmd"] not in deb[0], f"{display}: DEB card has another install command"
    )

# A manifest naming releases the repository no longer serves: the site keeps
# only the served ones (scripts/releases.env), each codename with its own
# version, and drops a distro left with none.
dists, releases = build_docs.served_releases()
check({"noble", "resolute"} <= dists and "jammy" not in dists, "served DEB dists are not the expected set")
check({"44", "45"} <= releases and "43" not in releases, "served Fedora releases are not the expected set")
stale = manifest(
    "stale", ["43", "44", "45"], "x86_64", ["resolute", "jammy", "noble"], ["26.04", "22.04", "24.04"], "s", "s"
)
stale["platforms"]["deb"]["distros"].append(
    {"id": "debian", "name": "Debian", "codenames": ["buster"], "versions": ["10"]}
)
build_docs._keep_served_releases(stale)
check(stale["platforms"]["rpm"]["distros"][0]["versions"] == ["44", "45"], "a retired Fedora release listed")
ubuntu = stale["platforms"]["deb"]["distros"]
check(len(ubuntu) == 1, "a distro with no served release kept")
check(ubuntu[0]["codenames"] == ["resolute", "noble"], "a retired Ubuntu release listed")
check(ubuntu[0]["versions"] == ["26.04", "24.04"], "codenames and versions no longer pair up")

print("build-docs.py: install cards per project OK")
