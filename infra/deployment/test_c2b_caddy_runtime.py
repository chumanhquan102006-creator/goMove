"""C2B local-only Caddy probe; creates and removes only uniquely named containers/network.

Run with a usable Docker Engine. No production Compose, volume, certificate or
public port is involved. The test hostname uses plain HTTP intentionally.
"""

import base64
import http.client
import json
from pathlib import Path
import socket
import subprocess
import time
import unittest
import uuid


HERE = Path(__file__).resolve().parent
CADDY = "caddy@sha256:4c6e91c6ed0e2fa03efd5b44747b625fec79bc9cd06ac5235a779726618e530d"
PYTHON = "python@sha256:e031123e3d85762b141ad1cbc56452ba69c6e722ebf2f042cc0dc86c47c0d8b3"
HOST = "c2b.example.invalid"


def docker(*args):
    return subprocess.run(["docker", *args], capture_output=True, text=True, check=True).stdout.strip()


class CaddyRuntimeTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.prefix = f"gomove-c2b-{uuid.uuid4().hex[:12]}"
        cls.network = cls.prefix
        cls.backend = cls.prefix + "-backend"
        cls.caddy = cls.prefix + "-caddy"
        cls.created = []
        try:
            docker("network", "create", cls.network)
            cls.created.append("network")
            docker(
                "run", "--detach", "--rm", "--name", cls.backend,
                "--network", cls.network, "--network-alias", "backend",
                "--read-only", "--tmpfs", "/tmp:rw,size=16m",
                "--mount", f"type=bind,source={HERE / 'c2b_mock_backend.py'},target=/app/mock.py,readonly",
                PYTHON, "python", "/app/mock.py",
            )
            cls.created.append(cls.backend)
            started = time.monotonic()
            docker(
                "run", "--detach", "--rm", "--name", cls.caddy,
                "--network", cls.network, "--publish", "127.0.0.1::80",
                "--env", f"M573_PUBLIC_HOSTNAME=http://{HOST}",
                "--mount", f"type=bind,source={HERE / 'Caddyfile.prod'},target=/etc/caddy/Caddyfile,readonly",
                CADDY, "caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile",
            )
            cls.created.append(cls.caddy)
            ports = json.loads(docker("inspect", "--format", "{{json .NetworkSettings.Ports}}", cls.caddy))
            cls.port = int(ports["80/tcp"][0]["HostPort"])
            for _ in range(40):
                try:
                    status, _, _ = cls.request("GET", "/api/v1/probe")
                    if status == 200:
                        break
                except (OSError, http.client.HTTPException):
                    pass
                time.sleep(0.25)
            else:
                raise AssertionError("Caddy or isolated mock upstream did not become ready")
            print(f"MEASURED: Caddy startup={time.monotonic()-started:.2f}s", flush=True)
            print("MEASURED:", docker("stats", "--no-stream", "--format", "cpu={{.CPUPerc}} memory={{.MemUsage}}", cls.caddy), flush=True)
        except Exception:
            cls.tearDownClass()
            raise

    @classmethod
    def tearDownClass(cls):
        for container in (cls.caddy, cls.backend):
            if container in cls.created:
                subprocess.run(["docker", "stop", container], capture_output=True, check=False)
        if "network" in cls.created:
            subprocess.run(["docker", "network", "rm", cls.network], capture_output=True, check=False)

    @classmethod
    def request(cls, method, path, body=None, headers=None):
        conn = http.client.HTTPConnection("127.0.0.1", cls.port, timeout=5)
        conn.request(method, path, body=body, headers={"Host": HOST, **(headers or {})})
        response = conn.getresponse()
        payload = response.read()
        result = response.status, dict(response.getheaders()), payload
        conn.close()
        return result

    def test_rest_and_forward_header_sanitization(self):
        status, _, data = self.request("POST", "/api/v1/probe", b"probe", {
            "Forwarded": "for=203.0.113.77;proto=https;host=evil.invalid",
            "X-Forwarded-For": "203.0.113.77",
            "X-Forwarded-Host": "evil.invalid",
            "X-Forwarded-Proto": "https",
            "X-Forwarded-Port": "443",
            "X-Real-IP": "203.0.113.77",
        })
        self.assertEqual(status, 200)
        result = json.loads(data)
        self.assertEqual(result["path"], "/api/v1/probe")
        self.assertEqual(result["body_size"], 5)
        received = result["headers"]
        self.assertNotIn("forwarded", received)
        self.assertNotIn("x-real-ip", received)
        self.assertNotIn("x-forwarded-port", received)
        self.assertNotIn("203.0.113.77", received.get("x-forwarded-for", ""))
        self.assertEqual(received.get("x-forwarded-host"), HOST)
        self.assertEqual(received.get("x-forwarded-proto"), "http")

    def test_private_and_unknown_paths_are_denied(self):
        for path in (
            "/actuator", "/actuator/health", "/swagger-ui/index.html",
            "/v3/api-docs", "/v3/api-docs/swagger-config", "/admin",
            "/ws/other", "/api/v2/probe",
        ):
            with self.subTest(path=path):
                status, _, _ = self.request("GET", path)
                self.assertEqual(status, 404)

    def test_body_limit_and_malformed_request(self):
        status, _, _ = self.request("POST", "/api/v1/probe", b"x" * (1024 * 1024 + 1))
        self.assertEqual(status, 413)
        with socket.create_connection(("127.0.0.1", self.port), timeout=5) as sock:
            sock.sendall(b"GET /api/v1/probe HTTP/1.1\r\nHost: c2b.example.invalid\r\nBad\x00Name: x\r\n\r\n")
            sock.settimeout(5)
            response = sock.recv(1024)
        self.assertIn(b"400 Bad Request", response)

    def test_websocket_upgrade(self):
        key = base64.b64encode(b"c2b-websocket-key").decode("ascii")
        status, headers, _ = self.request("GET", "/ws", headers={
            "Connection": "Upgrade", "Upgrade": "websocket", "Sec-WebSocket-Version": "13",
            "Sec-WebSocket-Key": key,
        })
        self.assertEqual(status, 101)
        self.assertEqual(headers.get("Upgrade", "").lower(), "websocket")


if __name__ == "__main__":
    unittest.main(verbosity=2)
