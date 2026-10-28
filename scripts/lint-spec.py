#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Check a quipchatwoot Flux spec against the limits Flux enforces late or silently.

    scripts/lint-spec.py deploy/flux/chatwoot-app-spec.json          # template: placeholders allowed
    scripts/lint-spec.py --filled deploy/flux/chatwoot.filled.json   # deployable: no placeholders

The dashboard's own validation is the authority; this catches what it reports
badly (its test install always says "Network Error") before a paste.
"""
import json
import re
import sys

MAX_ENV = 20        # environmentParameters per component
MAX_ENV_LEN = 400   # characters per entry
REPOTAG = re.compile(r"^[^@\s]+:[^@\s]+@sha256:[0-9a-f]{64}$")
PLACEHOLDER = re.compile(r"<[^>]+>")
# Values that must agree across components, or they connect to nothing.
SHARED = ("POSTGRES_PASSWORD", "REDIS_PASSWORD", "SECRET_KEY_BASE")


def main(argv):
    filled = "--filled" in argv
    paths = [a for a in argv if not a.startswith("--")]
    if len(paths) != 1:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    with open(paths[0]) as f:
        spec = json.load(f)

    errors, warnings = [], []
    if not re.fullmatch(r"[A-Za-z0-9]+", spec.get("name", "")) or spec["name"].lower().startswith("flux"):
        errors.append(f"app name {spec.get('name')!r}: alphanumeric only, must not start with 'flux'")
    if spec.get("version") != 8:
        errors.append("version must be 8 (single-instance needs v8)")
    if spec.get("nodes"):
        errors.append("nodes must stay empty (Priority Nodes disables geolocation and relocation choice)")

    shared = {}
    for c in spec.get("compose", []):
        name = c.get("name", "?")
        env = c.get("environmentParameters", [])
        if len(env) > MAX_ENV:
            errors.append(f"{name}: {len(env)} env vars, cap is {MAX_ENV}")
        for e in env:
            key, _, value = e.partition("=")
            if len(e) > MAX_ENV_LEN:
                errors.append(f"{name}: {key} is {len(e)} chars, cap is {MAX_ENV_LEN}")
            if not value:
                errors.append(f"{name}: {key} has an empty value (Flux rejects it)")
            if key in SHARED:
                shared.setdefault(key, set()).add(value)
        tag = c.get("repotag", "")
        if not REPOTAG.match(tag):
            (errors if filled else warnings).append(f"{name}: repotag is not repo:TAG@sha256:<64 hex>: {tag}")
        for field in ("cpu", "ram", "hdd"):
            if not isinstance(c.get(field), (int, float)) or c[field] <= 0:
                errors.append(f"{name}: {field} must be a positive number")
        print(f"  {name:9} env {len(env):2}/{MAX_ENV}  cpu {c['cpu']:<5} ram {c['ram']:<5} hdd {c['hdd']}")

    for key, values in shared.items():
        if len(values) > 1:
            errors.append(f"{key} differs between components")

    text = json.dumps(spec)
    holes = sorted(set(PLACEHOLDER.findall(text)) - {"<set-by-the-dashboard-Enterprise-toggle-at-submit>"})
    if holes:
        (errors if filled else warnings).append("placeholders remain: " + ", ".join(holes))

    for w in warnings:
        print(f"warn: {w}")
    for e in errors:
        print(f"FAIL: {e}")
    if errors:
        return 1
    print("ok" + (" (filled)" if filled else " (template)"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
