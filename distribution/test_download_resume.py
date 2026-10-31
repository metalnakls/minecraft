#!/usr/bin/env python3
"""Real HTTPS regression: interrupt, rerun, reuse, fallback and hash rejection."""
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import socket
import ssl
import subprocess
import tempfile
import threading

HERE = Path(__file__).resolve().parent
PAYLOAD = bytes(range(256)) * 512
HALF = len(PAYLOAD)//2

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.server.requests.append(self.headers.get('Range'))
        if self.server.mode == 'paused':
            if len(self.server.requests) == 1:
                self.send_response(200)
                self.send_header('Content-Length', str(len(PAYLOAD)))
                self.end_headers()
                self.wfile.write(PAYLOAD[:HALF]); self.wfile.flush()
                self.connection.shutdown(socket.SHUT_RDWR); self.connection.close()
            else:
                self.send_error(503)
            return
        offset = 0
        if self.headers.get('Range') and self.server.mode != 'no-range':
            offset = int(self.headers['Range'].split('=')[1].split('-')[0])
        if offset >= len(PAYLOAD):
            self.send_response(416)
            self.send_header('Content-Range', f'bytes */{len(PAYLOAD)}')
            self.end_headers(); return
        data = PAYLOAD[offset:]
        if self.server.mode == 'corrupt':
            data = b'x' * len(data)
        self.send_response(206 if offset else 200)
        if offset:
            self.send_header('Content-Range', f'bytes {offset}-{len(PAYLOAD)-1}/{len(PAYLOAD)}')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers(); self.wfile.write(data)
    def log_message(self, *args): pass

with tempfile.TemporaryDirectory(prefix='minecraft-resume-') as directory:
    root = Path(directory).resolve()
    cert, key = root/'cert.pem', root/'key.pem'
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                    '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost',
                    '-keyout', str(key), '-out', str(cert)], check=True, capture_output=True)
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); context.load_cert_chain(cert, key)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    server.requests = []; server.mode = 'paused'
    thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
    try:
        cache, stage = root/'cache', root/'stage'
        cache.mkdir(); stage.mkdir()
        progress = root/'progress.tsv'
        sha = hashlib.sha256(PAYLOAD).hexdigest()
        row = '\t'.join(('256', sha, '644', 'game/fixture.jar', f'https://localhost:{server.server_port}/fixture'))
        env = dict(os.environ, CURL_CA_BUNDLE=str(cert), MC_SETUP_PROGRESS=str(progress))
        command = ['/bin/bash', str(HERE/'install.template.sh'), '--fetch-row', str(root), str(cache), str(stage), row]
        first = subprocess.run(command, env=env, capture_output=True, text=True, timeout=30)
        assert first.returncode != 0, first.stdout+first.stderr
        partials = list(cache.glob('*.part'))
        assert len(partials)==1 and partials[0].read_bytes()==PAYLOAD[:HALF], first.stderr
        assert not (stage/'game/fixture.jar').exists()
        assert 'Rerun the same install command to resume' in first.stderr
        server.mode='healthy'; server.requests.clear()
        second = subprocess.run(command, env=env, capture_output=True, text=True, timeout=10)
        assert second.returncode==0, second.stdout+second.stderr
        assert server.requests==[f'bytes={HALF}-'], server.requests
        assert (stage/'game/fixture.jar').read_bytes()==PAYLOAD
        assert 'downloaded\tgame/fixture.jar' in progress.read_text()
        # New staging directory still reuses the verified content cache, offline.
        (stage/'game/fixture.jar').unlink(); server.requests.clear(); server.mode='paused'
        third = subprocess.run(command, env=env, capture_output=True, text=True, timeout=10)
        assert third.returncode==0 and server.requests==[], third.stderr
        assert 'cached\tgame/fixture.jar' in progress.read_text()
        print('PASS interrupted transfer retains bytes; second invocation requests only missing bytes; third invocation uses cache without network')
        # Range unsupported: discard only that partial and recover with full bytes.
        (stage/'game/fixture.jar').unlink(); (cache/f'256-{sha}').unlink()
        partials[0].write_bytes(PAYLOAD[:HALF]); server.mode='no-range'; server.requests.clear()
        fourth = subprocess.run(command, env=env, capture_output=True, text=True, timeout=15)
        assert fourth.returncode==0, fourth.stderr
        assert server.requests==[f'bytes={HALF}-', None], server.requests
        assert (stage/'game/fixture.jar').read_bytes()==PAYLOAD
        print('PASS server without ranges falls back to a verified full download')
        # A stale oversized partial receives 416 and must restart this file.
        (stage/'game/fixture.jar').unlink(); (cache/f'256-{sha}').unlink()
        partials[0].write_bytes(PAYLOAD+b'stale'); server.mode='healthy'; server.requests.clear()
        recovered = subprocess.run(command, env=env, capture_output=True, text=True, timeout=15)
        assert recovered.returncode==0, recovered.stderr
        assert server.requests==[f'bytes={len(PAYLOAD)+5}-', None], server.requests
        print('PASS invalid partial range restarts and verifies the file')
        # Corrupt server data must never be promoted into the cache or installation.
        (stage/'game/fixture.jar').unlink(); (cache/f'256-{sha}').unlink()
        server.mode='corrupt'; server.requests.clear()
        fifth = subprocess.run(command, env=env, capture_output=True, text=True, timeout=30)
        assert fifth.returncode!=0
        assert not (cache/f'256-{sha}').exists() and not (stage/'game/fixture.jar').exists()
        print('PASS checksum mismatch is rejected')
    finally:
        server.shutdown(); server.server_close(); thread.join()
