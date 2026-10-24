#!/usr/bin/env python3
"""Use one private, app-specific local signing identity across builds.

Does not add a trusted root or change system certificate trust. The identity and
its password stay in a 0700 directory outside the source tree.
"""
from pathlib import Path
import hashlib
import json
import os
import secrets
import subprocess
import sys
import tempfile


def run(args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, **kwargs)


def sign(app):
    store = Path.home() / "Library/Application Support/ScreenTranslatorSigning"
    store.mkdir(parents=True, exist_ok=True, mode=0o700)
    store.chmod(0o700)
    config_path = store / "identity.json"
    keychain = store / "local-signing.keychain-db"
    if config_path.exists():
        config = json.loads(config_path.read_text())
        if not keychain.exists():
            raise RuntimeError("Local signing keychain is missing; restore it before rebuilding.")
    else:
        if keychain.exists():
            raise RuntimeError("An unfinished local signing keychain exists; do not rotate its identity automatically.")
        password = secrets.token_urlsafe(32)
        existing_search_list = run(["security", "list-keychains", "-d", "user"], text=True).stdout
        import shlex
        search_list = shlex.split(existing_search_list)
        try:
            run(["security", "create-keychain", "-p", password, str(keychain)])
            run(["security", "set-keychain-settings", "-lut", "21600", str(keychain)])
            run(["security", "unlock-keychain", "-p", password, str(keychain)])
            with tempfile.TemporaryDirectory(dir=store) as temporary:
                temp = Path(temporary)
                settings = temp / "certificate.cnf"
                settings.write_text("""[req]
prompt = no
distinguished_name = subject
x509_extensions = extensions
[subject]
CN = ScreenTranslator Local Code Signing
O = Personal Local Development
[extensions]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
""")
                private_key = temp / "private.pem"
                certificate = temp / "certificate.pem"
                archive = temp / "identity.p12"
                run(["openssl", "req", "-new", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256",
                     "-days", "3650", "-config", str(settings), "-keyout", str(private_key), "-out", str(certificate)])
                env = dict(os.environ, SCREEN_TRANSLATOR_P12_PASSWORD=password)
                run(["openssl", "pkcs12", "-export", "-legacy", "-inkey", str(private_key), "-in", str(certificate),
                     "-name", "ScreenTranslator Local Code Signing", "-out", str(archive),
                     "-passout", "env:SCREEN_TRANSLATOR_P12_PASSWORD"], env=env)
                run(["security", "import", str(archive), "-k", str(keychain), "-P", password, "-T", "/usr/bin/codesign"])
                run(["security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", password, str(keychain)])
                der = run(["openssl", "x509", "-in", str(certificate), "-outform", "der"]).stdout
                fingerprint = hashlib.sha1(der).hexdigest().upper()
                (store / "certificate.pem").write_bytes(certificate.read_bytes())
                config = {"sha1": fingerprint, "password": password}
                config_path.write_text(json.dumps(config) + "\n")
                config_path.chmod(0o600)
        finally:
            # Keep the user's global/default keychain configuration unchanged.
            run(["security", "list-keychains", "-d", "user", "-s", *search_list])
    run(["security", "unlock-keychain", "-p", config["password"], str(keychain)])
    result = run(["/usr/bin/codesign", "--force", "--sign", config["sha1"], "--keychain", str(keychain),
                  "--timestamp=none", "--identifier", "local.gaoqi.screen-translator", str(app)], text=True)
    run(["/usr/bin/codesign", "--verify", "--strict", str(app)])
    details = run(["/usr/bin/codesign", "-d", "-r-", str(app)], text=True)
    requirement = details.stdout + details.stderr
    if "cdhash" in requirement or not ("certificate root" in requirement or "anchor" in requirement):
        raise RuntimeError("Signature is not a stable certificate-based identity.")
    print("Signed with stable app-specific local identity; no system trust settings changed.")


if __name__ == "__main__":
    try:
        sign(Path(sys.argv[1]).resolve())
    except subprocess.CalledProcessError as error:
        # Never print a command line containing a keychain password.
        print("Local signing failed: " + error.stderr.decode(errors="replace")[:600] if isinstance(error.stderr, bytes)
              else "Local signing failed: " + str(error.stderr)[:600], file=sys.stderr)
        sys.exit(1)
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
