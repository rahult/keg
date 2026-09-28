#!/usr/bin/env python3
"""Spike stand-in for the privileged port forwarder (needs root to bind :443).

Dumb TCP splice 127.0.0.1:443 -> 127.0.0.1:8443. No TLS, no HTTP — bytes in,
bytes out. Proves that a tiny root helper is all 443 needs; production would
be a ~150-line Swift launchd daemon.
"""
import socket
import threading

UPSTREAM = ("127.0.0.1", 8443)


def pipe(a, b):
    try:
        while True:
            d = a.recv(65536)
            if not d:
                break
            b.sendall(d)
    except OSError:
        pass
    finally:
        try:
            a.close()
        except OSError:
            pass
        try:
            b.close()
        except OSError:
            pass


def handle(c):
    try:
        u = socket.create_connection(UPSTREAM, timeout=5)
        threading.Thread(target=pipe, args=(c, u), daemon=True).start()
        pipe(u, c)
    except OSError:
        try:
            c.close()
        except OSError:
            pass


srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 443))
srv.listen(64)
print("splice: 127.0.0.1:443 -> 127.0.0.1:8443")
while True:
    c, _ = srv.accept()
    threading.Thread(target=handle, args=(c,), daemon=True).start()
