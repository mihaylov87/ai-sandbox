"""Unit and local integration tests for ai-sandbox-net (spec §9). WP4.

Python 3.9 stdlib only. Run: python3 -I tests/unit/net_test.py
Live tests use only loopback: the proxy's host-port exception (127.0.0.1:<port>) is the
one way it connects to a local test server; everything else must be refused.
"""

import http.server
import importlib.machinery
import importlib.util
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
NET = os.path.join(ROOT, "ai-sandbox-net")

_loader = importlib.machinery.SourceFileLoader("ais_net", NET)
_spec = importlib.util.spec_from_loader("ais_net", _loader)
net = importlib.util.module_from_spec(_spec)
_loader.exec_module(net)


class NormaliseTest(unittest.TestCase):
    def test_lower_case_and_trailing_dot(self):
        self.assertEqual(net.normalise_host("Example.COM."), "example.com")

    def test_idna(self):
        self.assertEqual(net.normalise_host("bücher.de"), "xn--bcher-kva.de")

    def test_bracketed_ipv6(self):
        self.assertEqual(net.normalise_host("[::1]"), "::1")

    def test_invalid_host_rejected(self):
        for bad in ["", "a b", "x/y", "..", "-"]:
            with self.assertRaises(ValueError, msg=bad):
                net.normalise_host(bad)


class AllowListTest(unittest.TestCase):
    def allow(self, *entries):
        return net.AllowList.parse("\n".join(entries))

    def test_plain_host_means_443_for_connect_and_80_for_http(self):
        a = self.allow("github.com")
        self.assertTrue(a.matches("github.com", 443, connect=True))
        self.assertTrue(a.matches("github.com", 80, connect=False))
        self.assertFalse(a.matches("github.com", 80, connect=True))
        self.assertFalse(a.matches("github.com", 22, connect=True))
        self.assertFalse(a.matches("api.github.com", 443, connect=True))

    def test_host_with_port(self):
        a = self.allow("github.com:22")
        self.assertTrue(a.matches("github.com", 22, connect=True))
        self.assertFalse(a.matches("github.com", 443, connect=True))

    def test_wildcard_matches_subdomains_not_the_domain(self):
        a = self.allow("*.githubcopilot.com")
        self.assertTrue(a.matches("api.githubcopilot.com", 443, connect=True))
        self.assertTrue(a.matches("a.b.githubcopilot.com", 443, connect=True))
        self.assertFalse(a.matches("githubcopilot.com", 443, connect=True))
        self.assertFalse(a.matches("evilgithubcopilot.com", 443, connect=True))

    def test_wildcard_with_port(self):
        a = self.allow("*.example.net:8443")
        self.assertTrue(a.matches("x.example.net", 8443, connect=True))
        self.assertFalse(a.matches("x.example.net", 443, connect=True))

    def test_case_trailing_dot_and_idna_in_entries_and_requests(self):
        a = self.allow("Bücher.DE.")
        self.assertTrue(a.matches("xn--bcher-kva.de", 443, connect=True))
        self.assertTrue(a.matches(net.normalise_host("BÜCHER.de."), 443, connect=True))

    def test_ip_literals_match_only_literal_entries(self):
        a = self.allow("10.1.2.3:8080", "[2001:db8::1]:443", "example.com")
        self.assertTrue(a.matches("10.1.2.3", 8080, connect=True))
        self.assertFalse(a.matches("10.1.2.4", 8080, connect=True))
        self.assertTrue(a.matches("2001:db8::1", 443, connect=True))
        self.assertFalse(a.matches("93.184.215.14", 443, connect=True))

    def test_comments_blank_lines_and_duplicates(self):
        a = self.allow("# comment", "", "  github.com  # trailing", "github.com")
        self.assertTrue(a.matches("github.com", 443, connect=True))

    def test_invalid_entries_raise(self):
        for bad in ["*.", "*", "github.com:0", "github.com:99999", "github.com:x", "a b", "*.*.com", "x*.com"]:
            with self.assertRaises(ValueError, msg=bad):
                self.allow(bad)


class PrivateRangeTest(unittest.TestCase):
    def test_private_addresses(self):
        for ip in ["127.0.0.1", "127.9.9.9", "10.0.0.1", "172.16.0.1", "172.31.255.255", "192.168.1.1",
                   "169.254.1.1", "169.254.169.254", "100.64.0.1", "100.127.255.255", "0.0.0.0",
                   "::1", "fe80::1", "fc00::1", "fd12:3456::1", "::", "::ffff:10.0.0.1", "::ffff:127.0.0.1"]:
            self.assertTrue(net.is_private(ip), ip)

    def test_public_addresses(self):
        for ip in ["8.8.8.8", "1.1.1.1", "172.32.0.1", "100.128.0.1", "2606:4700::1111", "::ffff:8.8.8.8"]:
            self.assertFalse(net.is_private(ip), ip)


def _free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


class _Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = ("hello " + self.path).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


class LiveProxyTest(unittest.TestCase):
    """Runs the proxy as a subprocess against a loopback HTTP server."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.allow = os.path.join(self.tmp, "allow")
        with open(self.allow, "w") as f:
            f.write("localhost\nlocalhost:%d\nexample.invalid\n" % self.port)
        self.log = os.path.join(self.tmp, "net.log")
        self.watched = subprocess.Popen(["sleep", "60"])
        self.proc = None

    def tearDown(self):
        if self.proc and self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait()
        self.watched.kill()
        self.watched.wait()
        self.server.shutdown()
        shutil.rmtree(self.tmp)

    def start(self, listen="tcp:127.0.0.1:0", host_ports=None, extra=()):
        hp = str(self.port) if host_ports is None else host_ports
        self.proc = subprocess.Popen(
            [sys.executable, "-I", NET, "proxy", "--listen", listen, "--allow-file", self.allow,
             "--host-ports", hp, "--log", self.log, "--watch-pid", str(self.watched.pid),
             "--kill-pgid", str(self.watched.pid)] + list(extra),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        line = self.proc.stdout.readline().decode().strip()
        self.assertTrue(line.startswith("READY "), line)
        addr = line.split(" ", 1)[1]
        if addr.startswith("tcp:"):
            host, port = addr[4:].rsplit(":", 1)
            self.addr = (socket.AF_INET, (host, int(port)))
        else:
            self.addr = (socket.AF_UNIX, addr[5:])
        return line

    def connect(self):
        s = socket.socket(self.addr[0], socket.SOCK_STREAM)
        s.settimeout(15)
        s.connect(self.addr[1])
        return s

    def request(self, raw):
        s = self.connect()
        s.sendall(raw)
        data = b""
        while True:
            chunk = s.recv(65536)
            if not chunk:
                break
            data += chunk
        s.close()
        return data

    def connect_tunnel(self, target):
        s = self.connect()
        s.sendall(("CONNECT %s HTTP/1.1\r\nHost: %s\r\n\r\n" % (target, target)).encode())
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = s.recv(1)
            if not chunk:
                break
            head += chunk
        return s, head.decode()

    def log_entries(self, n=1):
        """Wait (up to 5 s) until the log has at least n entries; a line is written when a
        connection ends."""
        deadline = time.time() + 5
        while True:
            entries = []
            if os.path.exists(self.log):
                with open(self.log) as f:
                    entries = [json.loads(line) for line in f if line.strip()]
            if len(entries) >= n or time.time() > deadline:
                return entries

    def test_ready_line_then_silence_on_stdout(self):
        self.start()
        self.proc.terminate()
        rest = self.proc.stdout.read()
        self.assertEqual(rest, b"")

    def test_connect_to_host_port_is_tunnelled(self):
        self.start()
        s, head = self.connect_tunnel("127.0.0.1:%d" % self.port)
        self.assertTrue(head.startswith("HTTP/1.1 200"), head)
        s.sendall(b"GET /tunnel HTTP/1.0\r\n\r\n")
        data = b""
        while True:
            c = s.recv(65536)
            if not c:
                break
            data += c
        self.assertIn(b"hello /tunnel", data)
        s.close()
        e = self.log_entries()[-1]
        self.assertEqual(e["verdict"], "allow")
        self.assertEqual(e["method"], "CONNECT")
        self.assertEqual(e["port"], self.port)
        for k in ("ts", "host", "ip", "up", "down", "ms"):
            self.assertIn(k, e)
        self.assertGreater(e["down"], 0)

    def test_plain_http_to_host_port_is_forwarded(self):
        self.start()
        data = self.request(("GET http://127.0.0.1:%d/plain HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n\r\n"
                             % (self.port, self.port)).encode())
        self.assertIn(b"hello /plain", data)

    def test_unlisted_host_gets_403_deny_host(self):
        self.start()
        s, head = self.connect_tunnel("example.com:443")
        self.assertTrue(head.startswith("HTTP/1.1 403"), head)
        self.assertEqual(self.log_entries()[-1]["verdict"], "deny:host")

    def test_unlisted_loopback_port_is_denied(self):
        self.start()
        s, head = self.connect_tunnel("127.0.0.1:%d" % _free_port())
        self.assertTrue(head.startswith("HTTP/1.1 403"), head)

    def test_listed_name_resolving_to_loopback_gets_deny_private(self):
        self.start(host_ports="")
        s, head = self.connect_tunnel("localhost:%d" % self.port)
        self.assertTrue(head.startswith("HTTP/1.1 403"), head)
        self.assertEqual(self.log_entries()[-1]["verdict"], "deny:private")

    def test_lan_and_metadata_literals_are_denied(self):
        self.start()
        for target in ["192.168.1.1:443", "169.254.169.254:80", "10.0.0.1:443"]:
            s, head = self.connect_tunnel(target)
            self.assertTrue(head.startswith("HTTP/1.1 403"), target + " " + head)

    def test_unresolvable_listed_host_is_an_error(self):
        self.start()
        s, head = self.connect_tunnel("example.invalid:443")
        self.assertTrue(head.startswith("HTTP/1.1 502"), head)
        self.assertEqual(self.log_entries()[-1]["verdict"], "error")

    def test_unix_socket_listener(self):
        path = os.path.join(self.tmp, "proxy.sock")
        line = self.start(listen="unix:" + path)
        self.assertEqual(line, "READY unix:" + path)
        s, head = self.connect_tunnel("127.0.0.1:%d" % self.port)
        self.assertTrue(head.startswith("HTTP/1.1 200"), head)

    def test_tunnel_limit_replies_503(self):
        self.start(extra=["--max-tunnels", "1"])
        s1, h1 = self.connect_tunnel("127.0.0.1:%d" % self.port)
        self.assertTrue(h1.startswith("HTTP/1.1 200"), h1)
        s2, h2 = self.connect_tunnel("127.0.0.1:%d" % self.port)
        self.assertTrue(h2.startswith("HTTP/1.1 503"), h2)
        s1.close()

    def test_malformed_request_gets_400(self):
        self.start()
        data = self.request(b"NONSENSE\r\n\r\n")
        self.assertTrue(data.startswith(b"HTTP/1.1 400"), data)

    def test_proxy_exits_and_kills_group_when_watched_pid_is_gone(self):
        group = subprocess.Popen(["sleep", "60"], start_new_session=True)
        self.proc = subprocess.Popen(
            [sys.executable, "-I", NET, "proxy", "--listen", "tcp:127.0.0.1:0", "--allow-file", self.allow,
             "--host-ports", "", "--log", self.log, "--watch-pid", str(self.watched.pid),
             "--kill-pgid", str(group.pid)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.proc.stdout.readline()
        self.watched.kill()
        self.watched.wait()
        self.proc.wait(timeout=10)
        group.wait(timeout=10)
        self.assertEqual(group.returncode, -signal.SIGTERM)


class WatchdogTest(unittest.TestCase):
    def test_terminates_group_then_exits(self):
        watched = subprocess.Popen(["sleep", "60"])
        group = subprocess.Popen(["sleep", "60"], start_new_session=True)
        wd = subprocess.Popen([sys.executable, "-I", NET, "watchdog", "--watch-pid", str(watched.pid),
                               "--kill-pgid", str(group.pid)], stdout=subprocess.PIPE)
        self.assertTrue(wd.stdout.readline().startswith(b"READY"))
        watched.kill()
        watched.wait()
        wd.wait(timeout=10)
        group.wait(timeout=10)
        self.assertEqual(group.returncode, -signal.SIGTERM)

    def test_sigkill_after_grace_when_group_ignores_sigterm(self):
        watched = subprocess.Popen(["sleep", "60"])
        group = subprocess.Popen(["sh", "-c", "trap '' TERM; sleep 60"], start_new_session=True)
        time.sleep(0.2)
        wd = subprocess.Popen([sys.executable, "-I", NET, "watchdog", "--watch-pid", str(watched.pid),
                               "--kill-pgid", str(group.pid), "--grace", "1"], stdout=subprocess.PIPE)
        wd.stdout.readline()
        watched.kill()
        watched.wait()
        group.wait(timeout=10)
        wd.wait(timeout=10)
        self.assertEqual(group.returncode, -signal.SIGKILL)


class BridgeTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        allow = os.path.join(self.tmp, "allow")
        open(allow, "w").close()
        self.sock = os.path.join(self.tmp, "proxy.sock")
        self.watched = subprocess.Popen(["sleep", "60"])
        self.proxy = subprocess.Popen(
            [sys.executable, "-I", NET, "proxy", "--listen", "unix:" + self.sock, "--allow-file", allow,
             "--host-ports", str(self.port), "--log", os.path.join(self.tmp, "log"),
             "--watch-pid", str(self.watched.pid), "--kill-pgid", str(self.watched.pid)],
            stdout=subprocess.PIPE)
        self.proxy.stdout.readline()
        self.procs = []

    def tearDown(self):
        for p in self.procs + [self.proxy, self.watched]:
            if p.poll() is None:
                p.kill()
                p.wait()
        self.server.shutdown()
        shutil.rmtree(self.tmp)

    def test_bridge_relays_bytes_to_the_proxy(self):
        b = subprocess.Popen([sys.executable, "-I", NET, "bridge", "--listen", "127.0.0.1:0",
                              "--upstream", "unix:" + self.sock], stdout=subprocess.PIPE)
        self.procs.append(b)
        line = b.stdout.readline().decode().strip()
        self.assertTrue(line.startswith("READY tcp:127.0.0.1:"), line)
        bport = int(line.rsplit(":", 1)[1])
        s = socket.create_connection(("127.0.0.1", bport), timeout=10)
        s.sendall(("CONNECT 127.0.0.1:%d HTTP/1.1\r\n\r\n" % self.port).encode())
        head = b""
        while b"\r\n\r\n" not in head:
            head += s.recv(1)
        self.assertTrue(head.startswith(b"HTTP/1.1 200"), head)
        s.sendall(b"GET /via-bridge HTTP/1.0\r\n\r\n")
        data = b""
        while True:
            c = s.recv(65536)
            if not c:
                break
            data += c
        self.assertIn(b"hello /via-bridge", data)

    @unittest.skipUnless(shutil.which("bwrap"), "bwrap needed for a private network namespace")
    def test_forward_port_inside_a_private_netns_reaches_the_host_port(self):
        client = ("import socket,sys; s=socket.create_connection(('127.0.0.1', %d), timeout=10);"
                  "s.sendall(b'GET /fwd HTTP/1.0\\r\\n\\r\\n'); d=b''\n"
                  "while True:\n c=s.recv(65536)\n if not c: break\n d+=c\n"
                  "sys.stdout.write(d.decode())") % self.port
        script = ("python3 -I %s bridge --upstream unix:%s --forward %d > %s/ready & "
                  "for i in $(seq 50); do [ -s %s/ready ] && break; sleep 0.1; done; python3 -I -c \"$1\"") % (
                      NET, self.sock, self.port, self.tmp, self.tmp)
        r = subprocess.run(["bwrap", "--unshare-net", "--unshare-pid", "--die-with-parent", "--ro-bind", "/", "/",
                            "--dev", "/dev", "--proc", "/proc", "--bind", self.tmp, self.tmp,
                            "sh", "-c", script, "sh", client], capture_output=True, timeout=30)
        self.assertIn(b"hello /fwd", r.stdout, r.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=1)
