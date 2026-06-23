#!/usr/bin/env python3
"""Re-seal all SealedSecrets against the current Sealed Secrets controller key.

Downloads each Secret from the live cluster, strips cluster metadata, re-seals
it with kubeseal, and writes the result back to the sealed secret file in flux/.

Usage:
    scripts/reseal-secrets.py            # dry-run: show what would be done
    scripts/reseal-secrets.py --apply    # download, re-seal, overwrite files

After running with --apply:
    rm -rf tmp/secrets/                  # delete plaintext immediately
    git diff flux/                       # review changed ciphertext
    git commit -m "security: re-seal all secrets with new Sealed Secrets key"
"""

import argparse
import json
import os
import shutil
import subprocess
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TMP_DIR = os.path.join(REPO_ROOT, "tmp", "secrets")

# sealed-secret-file -> (namespace, secret-name)
SECRETS = {
    "flux/trusted/vaultwarden/vaultwarden-sealedsecret.yaml":          ("vaultwarden",    "vaultwarden-secret"),
    "flux/trusted/siyuan/siyuan-sealedsecret.yaml":                    ("siyuan",         "siyuan-secret"),
    "flux/trusted/paperless-ngx/paperless-sealedsecret.yaml":          ("paperless-ngx",  "paperless-secret"),
    "flux/untrusted/karakeep/karakeep-sealedsecret.yaml":               ("karakeep",       "karakeep-secret"),
    "flux/untrusted/donetick/donetick-sealedsecret.yaml":               ("donetick",       "donetick-secret"),
    "flux/dmz/crowdsec/crowdsec-bouncer-sealedsecret.yaml":             ("traefik",        "crowdsec-bouncer-key"),
    "flux/dmz/authelia/authelia-sealedsecret.yaml":                     ("authelia",       "authelia-secrets"),
    "flux/dmz/traefik/traefik-porkbun-dns-sealedsecret.yaml":           ("traefik",        "traefik-dns-porkbun"),
    "flux/monitoring/alertmanager-email-sealedsecret.yaml":             ("monitoring",     "alertmanager-email-secret"),
    "flux/monitoring/alertmanager-telegram-sealedsecret.yaml":          ("monitoring",     "alertmanager-telegram-secret"),
    "flux/monitoring/admin-secret.yaml":                                ("monitoring",     "admin-secret"),
    "flux/monitoring/alertmanager-healthcheck-sealedsecret.yaml":       ("monitoring",     "alertmanager-healthchecks-secret"),
    "flux/infrastructure/config/longhorn/backup-secret.yaml":           ("longhorn-system","backup-secret"),
}

STRIP_FIELDS = {"creationTimestamp", "resourceVersion", "uid", "selfLink", "managedFields", "generation"}


def run(cmd, input=None, capture=True):
    result = subprocess.run(
        cmd,
        input=input,
        capture_output=capture,
        text=True,
    )
    return result


def strip_metadata(secret_json: str) -> str:
    doc = json.loads(secret_json)
    meta = doc.get("metadata", {})
    for field in STRIP_FIELDS:
        meta.pop(field, None)
    meta.pop("annotations", None)
    doc.pop("status", None)
    return json.dumps(doc)


def check_prerequisites():
    errors = []
    for tool in ("kubectl", "kubeseal"):
        if not shutil.which(tool):
            errors.append(f"  {tool} not found in PATH")
    if errors:
        print("Missing prerequisites:")
        for e in errors:
            print(e)
        sys.exit(1)

    result = run(["kubectl", "cluster-info"])
    if result.returncode != 0:
        print("kubectl cannot reach the cluster:")
        print(result.stderr)
        sys.exit(1)


def fetch_secret(namespace: str, name: str) -> str | None:
    result = run(["kubectl", "get", "secret", name, "-n", namespace, "-o", "json"])
    if result.returncode != 0:
        return None
    return result.stdout


def reseal(plaintext_json: str, namespace: str) -> str | None:
    result = run(
        ["kubeseal", "--format=yaml", "--namespace", namespace],
        input=plaintext_json,
    )
    if result.returncode != 0:
        print(f"    kubeseal error: {result.stderr.strip()}")
        return None
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--apply", action="store_true", help="Actually download, re-seal, and overwrite files")
    args = parser.parse_args()

    check_prerequisites()

    if args.apply:
        os.makedirs(TMP_DIR, mode=0o700, exist_ok=True)
        print(f"Plaintext secrets will be written to: {TMP_DIR}")
        print("DELETE THIS DIRECTORY IMMEDIATELY after the script completes.\n")

    print(f"{'DRY RUN — ' if not args.apply else ''}Processing {len(SECRETS)} secrets\n")

    ok = []
    skipped = []
    failed = []

    for sealed_file, (namespace, name) in SECRETS.items():
        print(f"  {namespace}/{name}")

        if not args.apply:
            print(f"    would fetch and re-seal -> {sealed_file}")
            continue

        # Fetch
        raw = fetch_secret(namespace, name)
        if raw is None:
            print(f"    SKIP — secret not found in cluster (namespace/app not deployed yet?)")
            skipped.append(sealed_file)
            continue

        # Strip metadata and save plaintext
        plaintext = strip_metadata(raw)
        tmp_path = os.path.join(TMP_DIR, f"{namespace}-{name}.json")
        with open(tmp_path, "w") as f:
            f.write(plaintext)

        # Re-seal
        sealed = reseal(plaintext, namespace)
        if sealed is None:
            print(f"    FAILED — kubeseal error (see above)")
            failed.append(sealed_file)
            continue

        # Overwrite sealed secret file
        dest = os.path.join(REPO_ROOT, sealed_file)
        with open(dest, "w") as f:
            f.write(sealed)

        print(f"    OK -> {sealed_file}")
        ok.append(sealed_file)

    print(f"\n{'=' * 60}")
    if args.apply:
        print(f"  Done: {len(ok)} re-sealed, {len(skipped)} skipped, {len(failed)} failed")
        if skipped:
            print(f"\n  Skipped (not running in cluster):")
            for f in skipped:
                print(f"    {f}")
        if failed:
            print(f"\n  Failed:")
            for f in failed:
                print(f"    {f}")
        print(f"""
  Next steps:
    1. Delete plaintext secrets NOW:
         rm -rf {TMP_DIR}

    2. Review changes:
         git diff flux/

    3. Commit:
         git add flux/
         git commit -m "security: re-seal all secrets with new Sealed Secrets key"
""")
    else:
        print("  Dry run complete — run with --apply to execute")


if __name__ == "__main__":
    main()
