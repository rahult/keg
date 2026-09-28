#!/usr/bin/env python3
"""Spike TLS server: static page on 127.0.0.1:8443 with the wildcard *.keg leaf.

Stands in for the future in-app gateway proxy — the spike only needs a TLS
endpoint to prove resolution + trust + forwarding. Echoes the Host header so
the browser visibly shows which name routed here.
"""
import http.server
import os
import ssl
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PORT = 8443


class Handler(http.server.BaseHTTPRequestHandler):
    def _serve(self):
        host = self.headers.get("Host", "?")
        body = (
            "<html><body style='font-family:-apple-system,sans-serif;padding:3rem'>"
            "<h1>&#9989; keg gateway spike</h1>"
            f"<p>Served over TLS for <b>{host}</b> from 127.0.0.1:{PORT}.</p>"
            "<p>If the padlock is valid, the whole chain works.</p>"
            "</body></html>"
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    do_GET = _serve
    do_HEAD = _serve

    def log_message(self, *args):
        pass


ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
cert = sys.argv[1] if len(sys.argv) > 1 else "pki/leaf-fullchain.pem"
ctx.load_cert_chain(
    os.path.join(HERE, cert), os.path.join(HERE, cert.replace("-fullchain.pem", ".key"))
)
print(f"tlsserver: https://127.0.0.1:{PORT} (leaf: {cert})")
srv = http.server.HTTPServer(("127.0.0.1", PORT), Handler)
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
print(f"tlsserver: https://127.0.0.1:{PORT} (leaf: *.keg)")
srv.serve_forever()
