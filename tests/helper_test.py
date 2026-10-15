"""Exercise the compiled helper against an authenticated local test server."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

HELPER = Path(__file__).resolve().parents[1] / "dist/GrammarNazi.app/Contents/Resources/grammarnazi-helper"
SERVER = r'''
import http.server, json, os, pathlib, sys, time
args = sys.argv[1:]
def arg(key): return args[args.index(key) + 1]
model = pathlib.Path(arg("--model"))
model.with_suffix(".pid").write_text(str(os.getpid()))
assert arg("--host") == "127.0.0.1"
assert arg("--parallel") == "1"
assert "--embedding" not in args
assert json.loads(arg("--chat-template-kwargs"))["enable_thinking"] is False
key = pathlib.Path(arg("--api-key-file")).read_text()
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b'{"status":"ok"}')
    def do_POST(self):
        assert self.path == "/v1/chat/completions"
        assert self.headers["Authorization"] == "Bearer " + key
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        model.with_suffix(".request").write_text(json.dumps(body))
        if body.get("slow"): time.sleep(10)
        self.send_response(400 if body.get("fail") else 200); self.end_headers()
        response = {"error":{"message":"Test model failure"}} if body.get("fail") else {"choices":[{"finish_reason":"stop","message":{"content":"Corrected text."}}]}
        self.wfile.write(json.dumps(response).encode())
http.server.HTTPServer((arg("--host"), int(arg("--port"))), Handler).serve_forever()
'''

class HelperTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="grammarnazi-helper-test-")
        self.folder = Path(self.tmp.name)
        self.server = self.folder / "fake-server"
        self.server.write_text("#!" + sys.executable + "\n" + SERVER)
        self.server.chmod(0o755)
        self.model = self.folder / "model.gguf"
        self.model.touch()
        self.request = self.folder / "request.json"

    def tearDown(self):
        self.tmp.cleanup()

    def invoke(self, body):
        self.request.write_text(json.dumps(body))
        return subprocess.Popen([str(HELPER), str(self.server), str(self.model), str(self.request)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def assert_server_stopped(self):
        pid = int(self.model.with_suffix(".pid").read_text())
        with self.assertRaises(ProcessLookupError): os.kill(pid, 0)

    def test_inference_and_cleanup(self):
        process = self.invoke({"messages": [{"role": "user", "content": "Fix this."}], "stream": False})
        stdout, stderr = process.communicate(timeout=15)
        self.assertEqual(process.returncode, 0, stderr.decode())
        self.assertEqual(json.loads(stdout)["choices"][0]["message"]["content"], "Corrected text.")
        self.assert_server_stopped()

    def test_http_error_and_cleanup(self):
        process = self.invoke({"fail": True})
        stdout, stderr = process.communicate(timeout=15)
        self.assertEqual(process.returncode, 1)
        self.assertEqual(stdout, b"")
        self.assertIn(b"Test model failure", stderr)
        self.assert_server_stopped()

    def test_termination_reaps_server(self):
        process = self.invoke({"slow": True})
        deadline = time.monotonic() + 10
        while not self.model.with_suffix(".request").exists() and time.monotonic() < deadline: time.sleep(0.02)
        self.assertTrue(self.model.with_suffix(".request").exists())
        process.send_signal(signal.SIGTERM)
        process.communicate(timeout=5)
        self.assertIn(process.returncode, (1, 128 + signal.SIGTERM))
        self.assert_server_stopped()

    def test_missing_model(self):
        self.model.unlink()
        process = self.invoke({"messages": []})
        _, stderr = process.communicate(timeout=5)
        self.assertEqual(process.returncode, 1)
        self.assertIn(b"GGUF model is missing", stderr)
        self.assertFalse(self.model.with_suffix(".pid").exists())

if __name__ == "__main__": unittest.main()
