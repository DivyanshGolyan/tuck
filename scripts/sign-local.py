#!/usr/bin/env python3
"""Sign using this user's persistent, certificate-bound development identity.
Never adds certificate trust or changes privacy permissions. Secrets stay off stdout.
"""
import json
from pathlib import Path
import re
import subprocess
import sys


def run(*args):
    result = subprocess.run(args, capture_output=True, text=True, check=False)
    if result.returncode:
        raise RuntimeError(f"{args[0]} {args[1]} failed: {result.stderr.strip()}")
    return result.stdout


def search_list():
    return re.findall(r'"([^"]+)"', run("/usr/bin/security", "list-keychains", "-d", "user"))


def main():
    if len(sys.argv) != 2:
        raise SystemExit("Usage: sign-local.py APP")
    metadata = Path.home() / ".local/share/tuck/signing/identity.json"
    identity = json.loads(metadata.read_text())
    keychain = identity["keychain"]
    password = run("/usr/bin/security", "find-generic-password", "-a", identity["account"],
                   "-s", identity["passwordService"], "-w").rstrip("\n")
    original = search_list()
    added = keychain not in original
    try:
        if added:
            run("/usr/bin/security", "list-keychains", "-d", "user", "-s", *original, keychain)
        run("/usr/bin/security", "unlock-keychain", "-p", password, keychain)
        run("/usr/bin/codesign", "--force", "--sign", identity["fingerprint"],
            "--keychain", keychain, "--timestamp=none", "--identifier", "local.tuck", sys.argv[1])
        run("/usr/bin/codesign", "--verify", "--strict", sys.argv[1])
        print("Signed with persistent local development identity " + identity["fingerprint"])
    finally:
        if added:
            # Remove only our temporary addition; retain unrelated concurrent changes.
            current = search_list()
            if keychain in current:
                run("/usr/bin/security", "list-keychains", "-d", "user", "-s",
                    *(entry for entry in current if entry != keychain))


if __name__ == "__main__":
    main()
