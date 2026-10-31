#!/usr/bin/env python3
"""Exercise the actual installer downloader against a TLS server that drops once."""
import hashlib
from http.server import BaseHTTPRequestHandler, HTTPServer
import os
from pathlib import Path
import socket
import ssl
import subprocess
import tempfile
import threading

HERE = Path(__file__).resolve().parent
PAYLOAD = b'installer transport regression fixture\n'

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Length', str(len(PAYLOAD)))
        self.end_headers()
        self.wfile.write(PAYLOAD)
    def log_message(self, *args):
        pass

class DropOnceServer(HTTPServer):
    def get_request(self):
        connection, address = self.socket.accept()
        self.accepted += 1
        if self.accepted == 1:
            connection.close()
            raise OSError('intentional TLS connection close')
        return self.context.wrap_socket(connection, server_side=True), address

def run_case(root, fixed, cert, key):
    server = DropOnceServer(('127.0.0.1', 0), Handler)
    server.accepted = 0
    server.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    server.context.load_cert_chain(cert, key)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        case = root/('fixed' if fixed else 'before')
        case.mkdir()
        (case/'cache').mkdir()
        (case/'stage').mkdir()
        text = (HERE/'install.template.sh').read_text()
        if not fixed:
            text = text.replace(' --retry-all-errors', '')
            original = 'download_verified "$url" "$tmp" "$algorithm" "$expected" || return 1'
            assert original in text
            text = text.replace(original, 'get "$url" "$tmp" || return 1')
        script = case/'install.sh'
        script.write_text(text)
        sha = hashlib.sha256(PAYLOAD).hexdigest()
        row = '\t'.join(('256', sha, '644', 'game/fixture.jar', f'https://localhost:{server.server_port}/fixture'))
        env = dict(os.environ, CURL_CA_BUNDLE=str(cert))
        result = subprocess.run(['bash',str(script),'--fetch-row',str(case),str(case/'cache'),str(case/'stage'),row],
                                env=env,capture_output=True,text=True,timeout=30)
        if fixed:
            assert result.returncode == 0, result.stderr
            assert (case/'stage/game/fixture.jar').read_bytes() == PAYLOAD
            assert server.accepted >= 2
        else:
            assert result.returncode != 0, 'Old downloader unexpectedly survived the dropped TLS handshake'
            assert not (case/'stage/game/fixture.jar').exists()
        print(('PASS fixed retries and verifies bytes' if fixed else 'PASS reproduced original TLS failure'),
              f'(exit={result.returncode}, connections={server.accepted})')
    finally:
        server.shutdown()
        server.server_close()
        thread.join()

if __name__ == '__main__':
    with tempfile.TemporaryDirectory(prefix='minecraft-tls-test-') as tmp:
        root=Path(tmp);cert=root/'cert.pem';key=root/'key.pem'
        subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','1',
                        '-subj','/CN=localhost','-addext','subjectAltName=DNS:localhost',
                        '-keyout',str(key),'-out',str(cert)],check=True,capture_output=True)
        run_case(root,False,cert,key)
        run_case(root,True,cert,key)
