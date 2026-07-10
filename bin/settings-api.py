#!/usr/bin/env python3
"""Minimal HTTP server for settings.yml read/write API."""

import http.server
import json
import os
import sys
import yaml
from datetime import datetime, timezone

SETTINGS_PATH = os.environ.get("SETTINGS_PATH", "/cert-updater/config/settings.yml")
SCHEMA_PATH = os.environ.get("SETTINGS_SCHEMA_PATH", "/cert-updater/web/settings.schema.json")
PORT = int(os.environ.get("SETTINGS_API_PORT", "8081"))


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


class SettingsHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # suppress logs

    def _send_json(self, code, data):
        body = json.dumps(data, indent=2).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/api/settings/read":
            try:
                with open(SETTINGS_PATH, "r") as f:
                    content = f.read()
                self.send_response(200)
                self.send_header("Content-Type", "text/yaml")
                self.send_header("Content-Length", str(len(content.encode())))
                self.end_headers()
                self.wfile.write(content.encode())
            except FileNotFoundError:
                self._send_json(404, {"error": "settings.yml not found"})
            except Exception as e:
                self._send_json(500, {"error": str(e)})
        else:
            self._send_json(404, {"error": "not found"})

    def do_POST(self):
        if self.path == "/api/settings/write":
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
    server = http.server.HTTPServer(("0.0.0.0", PORT), SettingsHandler)
    print(f"Settings API server listening on port {PORT}", flush=True)
    server.serve_forever()
