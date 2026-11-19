#!/usr/bin/env python3
"""Flag potentially sensitive additions before dependency updates execute."""

import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

SUBMODULES = {"LoopKit", "G7SensorKit", "OmnipodKit", "RileyLinkKit"}
SOURCE = re.compile(
    r"(?i)(\.(swift|m|mm|h|c|cc|cpp|rb|py|sh|js|ts|jsx|tsx|plist|entitlements|"
    r"pbxproj|xcconfig|yml|yaml|json|xml|html|podspec|gemspec|gradle|kt|java)$|"
    r"(^|/)(Gemfile|Podfile|Makefile|Package\.swift)$)"
)
RULES = {
    "network access": re.compile(r"\b(URLSession|URLRequest|NWConnection|CFNetwork|Net::HTTP|HTTPClient|NSURLSession|WebSocket|fetch|XMLHttpRequest|curl|wget|socket)\b", re.I),
    "sensitive data or device access": re.compile(r"\b(HealthKit|HKHealthStore|CoreLocation|CLLocationManager|Contacts|CNContactStore|AVCaptureDevice|SecItem(Add|CopyMatching|Update|Delete)|Keychain|CBCentralManager|CBPeripheralManager|CoreBluetooth|FileManager)\b|\bENV\s*\[|\bos\.environ\b|\bProcessInfo\b.*\benvironment\b", re.I),
    "process execution or dynamic code": re.compile(r"\b(eval|exec|spawn|popen|system|NSTask|Process|posix_spawn|dlopen|dlsym)\s*[(.]|`[^`]+`"),
    "encoded or unusually dense content": re.compile(r"[A-Za-z0-9+/]{200,}={0,2}|\\x[0-9a-fA-F]{2}(?:\\x[0-9a-fA-F]{2}){15,}"),
}
VERSION = re.compile(r"""^\s*gem\s+["']fastlane["']\s*,\s*["'](\d+(?:\.\d+)+)["']""", re.M)


def command(args, *, cwd=None, diff=False):
    env = dict(os.environ, GIT_EXTERNAL_DIFF="", GIT_CONFIG_NOSYSTEM="1")
    result = subprocess.run(args, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode not in ((0, 1) if diff else (0,)):
        raise RuntimeError(f"{args[0]} failed: {result.stderr.decode('utf-8', 'replace')[:1000]}")
    return result.stdout.decode("utf-8", "replace")


def scan_diff(diff, dependency):
    findings = []
    path = ""
    line_number = 0
    for line in diff.splitlines():
        if line.startswith("diff --git "):
            path = ""
        elif line.startswith("+++ "):
            path = line[4:]
        elif line.startswith("Binary files ") or line.startswith("GIT binary patch"):
            findings.append((dependency, "binary file changed", "see dependency diff"))
        elif line.startswith("@@ "):
            match = re.search(r"\+(\d+)", line)
            line_number = int(match.group(1)) if match else 0
        elif line.startswith("+") and not line.startswith("+++"):
            if line.startswith("+Subproject commit "):
                findings.append((dependency, "nested submodule changed; not scanned", path))
            elif SOURCE.search(path):
                content = line[1:]
                if len(content) >= 500 and not re.search(r"\s", content):
                    findings.append((dependency, "unusually long dense line", f"{path}:{line_number}"))
                for label, pattern in RULES.items():
                    if pattern.search(content):
                        findings.append((dependency, label, f"{path}:{line_number}"))
            line_number += 1
        elif line.startswith(" "):
            line_number += 1
    return findings


def fastlane_diff():
    original = command(["git", "show", "HEAD:Gemfile"])
    updated = Path("Gemfile").read_text()
    versions = [VERSION.search(text) for text in (original, updated)]
    if not all(versions):
        raise RuntimeError("Cannot determine both pinned fastlane versions")
    old, new = (match.group(1) for match in versions)
    if old == new:
        return ""
    with tempfile.TemporaryDirectory(prefix="dependency-scan-") as directory:
        paths = []
        for version in (old, new):
            command(["gem", "fetch", "fastlane", "--version", version,
                     "--clear-sources", "--source", "https://rubygems.org"], cwd=directory)
            gem_file = f"fastlane-{version}.gem"
            command(["gem", "unpack", gem_file, "--target", directory], cwd=directory)
            paths.append(str(Path(directory) / f"fastlane-{version}"))
        return command(["git", "diff", "--no-index", "--no-ext-diff", "--no-textconv",
                        "--unified=0", "--", *paths], diff=True)


def main(dependencies):
    if not dependencies or any(name not in SUBMODULES | {"fastlane"} for name in dependencies):
        raise RuntimeError("Select supported dependencies to scan")
    findings = []
    for name in dependencies:
        if name == "fastlane":
            diff = fastlane_diff()
        else:
            old = command(["git", "rev-parse", f"HEAD:{name}"]).strip()
            diff = command(["git", "-C", name, "diff", "--no-ext-diff", "--no-textconv",
                            "--no-renames", "--unified=0", old, "HEAD", "--"])
        findings.extend(scan_diff(diff, name))
    print("### Dependency change scan")
    print("Heuristics inspect added source lines, changed binaries and nested submodules. "
          "Fastlane's transitive gems are not scanned. A clean result does not mean an update is safe.")
    if findings:
        print(f"\n**Review required:** {len(findings)} potential issues; update stopped.")
        for dependency, rule, location in findings[:100]:
            safe_location = location.replace("\n", " ").replace("`", "'")
            print(f"- {dependency}: {rule} (`{safe_location}`)")
        if len(findings) > 100:
            print(f"- {len(findings) - 100} additional findings omitted.")
        return 1
    print("\nNo heuristic findings.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (OSError, RuntimeError) as error:
        print(f"Dependency scan failed; update stopped: {error}", file=sys.stderr)
        sys.exit(1)
