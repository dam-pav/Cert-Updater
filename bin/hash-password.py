#!/usr/bin/env python3
"""Generate a PBKDF2 password hash for config/users.json."""

import base64
import getpass
import hashlib
import secrets

HASH_ALGORITHM = "pbkdf2_sha256"
HASH_ITERATIONS = 260000


def main():
    password = getpass.getpass("Password: ")
    confirm = getpass.getpass("Confirm password: ")
    if password != confirm:
        raise SystemExit("Passwords do not match")

    salt = secrets.token_hex(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), salt.encode(), HASH_ITERATIONS)
    encoded = base64.b64encode(digest).decode()
    print(f"{HASH_ALGORITHM}${HASH_ITERATIONS}${salt}${encoded}")


if __name__ == "__main__":
    main()
