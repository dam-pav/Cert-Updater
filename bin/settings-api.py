#!/usr/bin/env python3
"""Minimal HTTP server for authenticated status and settings APIs."""

import base64
import binascii
import hashlib
import hmac
import http.server
import json
import os
import secrets
import yaml
from datetime import datetime, timezone
from urllib.parse import urlparse

SETTINGS_PATH = os.environ.get("SETTINGS_PATH", "/cert-updater/config/settings.yml")
SCHEMA_PATH = os.environ.get("SETTINGS_SCHEMA_PATH", "/cert-updater/web/settings.schema.json")
CREDENTIALS_PATH = os.environ.get("CREDENTIALS_PATH", "/cert-updater/config/users.json")
STATUS_PATH = os.environ.get("STATUS_PATH", "/cert-updater/export/status.json")
PORT = int(os.environ.get("SETTINGS_API_PORT", "8081"))
DEFAULT_USERNAME = "admin"
DEFAULT_PASSWORD = "admin"
DEFAULT_ROLE = "admin"
HASH_ALGORITHM = "pbkdf2_sha256"
HASH_ITERATIONS = 260000


def load_schema():
    schema_path = SCHEMA_PATH
    if "SETTINGS_SCHEMA_PATH" not in os.environ and not os.path.exists(schema_path):
        repo_schema_path = os.path.abspath(
            os.path.join(os.path.dirname(__file__), "..", "web", "settings.schema.json")
        )
        if os.path.exists(repo_schema_path):
            schema_path = repo_schema_path

    with open(schema_path, "r") as f:
        return json.load(f)


SCHEMA = load_schema()


def hash_password(password, salt=None, iterations=HASH_ITERATIONS):
    salt = salt or secrets.token_hex(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), salt.encode(), iterations)
    encoded = base64.b64encode(digest).decode()
    return f"{HASH_ALGORITHM}${iterations}${salt}${encoded}"


def verify_password(password, encoded):
    try:
        algorithm, iterations, salt, digest = encoded.split("$", 3)
        if algorithm != HASH_ALGORITHM:
            return False
        candidate = hash_password(password, salt=salt, iterations=int(iterations))
        return hmac.compare_digest(candidate, encoded)
    except (TypeError, ValueError, binascii.Error):
        return False


def default_credentials():
    return {
        "users": [
            {
                "username": DEFAULT_USERNAME,
                "password_hash": hash_password(DEFAULT_PASSWORD),
                "role": DEFAULT_ROLE,
                "must_change_password": True,
            }
        ]
    }


def ensure_credentials_file():
    if os.path.exists(CREDENTIALS_PATH):
        return

    credentials = default_credentials()
    try:
        os.makedirs(os.path.dirname(CREDENTIALS_PATH), exist_ok=True)
        with open(CREDENTIALS_PATH, "w") as f:
            json.dump(credentials, f, indent=2)
            f.write("\n")
        os.chmod(CREDENTIALS_PATH, 0o600)
        print(
            f"Created default credentials at {CREDENTIALS_PATH}; "
            f"login with {DEFAULT_USERNAME}/{DEFAULT_PASSWORD} and replace it.",
            flush=True,
        )
    except Exception as e:
        print(f"WARNING: failed to create credentials file: {e}", flush=True)


def load_credentials():
    ensure_credentials_file()
    try:
        with open(CREDENTIALS_PATH, "r") as f:
            data = json.load(f)
    except FileNotFoundError:
        data = default_credentials()

    users = data.get("users", [])
    if not isinstance(users, list):
        return []
    return [user for user in users if isinstance(user, dict)]


def find_authenticated_user(header):
    if not header or not header.startswith("Basic "):
        return None

    try:
        raw = base64.b64decode(header[6:], validate=True).decode()
        username, password = raw.split(":", 1)
    except (ValueError, UnicodeDecodeError, binascii.Error):
        return None

    for user in load_credentials():
        if user.get("username") == username and verify_password(password, user.get("password_hash")):
            role = user.get("role")
            if role not in ("viewer", "admin"):
                return None
            return {
                "username": username,
                "role": role,
                "must_change_password": bool(user.get("must_change_password")),
            }
    return None


def role_allows(user, required_role):
    if not user:
        return False
    if required_role == "viewer":
        return user.get("role") in ("viewer", "admin")
    if required_role == "admin":
        return user.get("role") == "admin"
    return False


class SettingsHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # suppress logs

    def _send_json(self, code, data, extra_headers=None):
        body = json.dumps(data, indent=2).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for name, value in (extra_headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def _send_text(self, code, content, content_type):
        body = content.encode()
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _require_role(self, role):
        user = find_authenticated_user(self.headers.get("Authorization"))
        if role_allows(user, role):
            return user
        self._send_json(
            401 if not user else 403,
            {"error": "authentication required" if not user else "admin access required"},
            {"WWW-Authenticate": 'Basic realm="Certificate Updater"'} if not user else None,
        )
        return None

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/api/auth/me":
            user = self._require_role("viewer")
            if not user:
                return
            self._send_json(200, user)
        elif path in ("/api/status", "/status.json"):
            if not self._require_role("viewer"):
                return
            try:
                with open(STATUS_PATH, "r") as f:
                    self._send_text(200, f.read(), "application/json")
            except FileNotFoundError:
                self._send_json(404, {"error": "status.json not found"})
            except Exception as e:
                self._send_json(500, {"error": str(e)})
        elif path == "/api/settings/read":
            if not self._require_role("admin"):
                return
            try:
                with open(SETTINGS_PATH, "r") as f:
                    self._send_text(200, f.read(), "text/yaml")
            except FileNotFoundError:
                self._send_json(404, {"error": "settings.yml not found"})
            except Exception as e:
                self._send_json(500, {"error": str(e)})
        else:
            self._send_json(404, {"error": "not found"})

    def do_POST(self):
        path = urlparse(self.path).path
        if path == "/api/settings/write":
            if not self._require_role("admin"):
                return
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length).decode() if length else ""

            # Validate YAML syntax
            try:
                data = yaml.safe_load(body)
            except yaml.YAMLError as e:
                self._send_json(400, {"error": f"Invalid YAML: {e}"})
                return

            if not isinstance(data, dict):
                self._send_json(400, {"error": "Root element must be a YAML mapping (object)"})
                return

            # Validate against schema
            errors = validate_against_schema(data, SCHEMA)
            errors.extend(validate_host_references(data))
            if errors:
                self._send_json(400, {"error": "Validation failed", "details": errors})
                return

            # Write file
            try:
                with open(SETTINGS_PATH, "w") as f:
                    f.write(body)
                self._send_json(200, {
                    "status": "ok",
                    "message": "settings.yml updated successfully",
                    "timestamp": datetime.now(timezone.utc).isoformat()
                })
            except Exception as e:
                self._send_json(500, {"error": f"Failed to write file: {e}"})
        else:
            self._send_json(404, {"error": "not found"})


def validate_against_schema(data, schema):
    """Simple schema validator supporting type, required, enum, properties, items."""
    errors = []
    if schema is True:
        return errors
    if schema is False:
        return ["Unknown field is not allowed"]

    # Type check
    if "type" in schema:
        expected = schema["type"]
        if expected == "object" and not isinstance(data, dict):
            errors.append(f"Expected object, got {type(data).__name__}")
            return errors
        elif expected == "array" and not isinstance(data, list):
            errors.append(f"Expected array, got {type(data).__name__}")
            return errors
        elif expected == "string" and not isinstance(data, str):
            errors.append(f"Expected string, got {type(data).__name__}")
            return errors

    # Required fields (for objects)
    if schema.get("type") == "object" and "required" in schema:
        for field in schema["required"]:
            if field not in data:
                errors.append(f"Missing required field: '{field}'")

    # Properties validation
    if schema.get("type") == "object":
        properties = schema.get("properties", {})
        for prop, value in data.items():
            if prop in properties:
                prop_schema = properties[prop]
            else:
                additional = schema.get("additionalProperties", False)
                if additional is True:
                    continue
                if additional is False:
                    errors.append(f"Unknown field: '{prop}'")
                    continue
                prop_schema = additional

            sub_errors = validate_against_schema(value, prop_schema)
            for e in sub_errors:
                errors.append(f"{prop}.{e}" if prop else e)

    # Array items validation
    if schema.get("type") == "array" and "items" in schema:
        for i, item in enumerate(data):
            sub_errors = validate_against_schema(item, schema["items"])
            for e in sub_errors:
                errors.append(f"[{i}].{e}" if i else f".{e}")

    # Enum check
    if "enum" in schema and data not in schema["enum"]:
        errors.append(f"Value must be one of: {schema['enum']}")

    return errors


def validate_host_references(data):
    """Ensure every domain host points to a key in the hosts section."""
    if not isinstance(data.get("domains"), list):
        return []

    errors = []
    host_names = set(data["hosts"].keys()) if isinstance(data.get("hosts"), dict) else set()
    for index, domain in enumerate(data["domains"]):
        if not isinstance(domain, dict) or not isinstance(domain.get("host"), str):
            continue
        if domain["host"] not in host_names:
            if host_names:
                errors.append(
                    f"domains[{index}].host: '{domain['host']}' does not match any configured host"
                )
            else:
                errors.append(
                    f"domains[{index}].host: '{domain['host']}' cannot be resolved because no hosts are configured"
                )
    return errors


if __name__ == "__main__":
    ensure_credentials_file()
    server = http.server.HTTPServer(("0.0.0.0", PORT), SettingsHandler)
    print(f"Settings API server listening on port {PORT}", flush=True)
    server.serve_forever()
