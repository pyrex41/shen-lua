#!/usr/bin/env python3
"""Local HTTP and HTTPS mock for the unii network adapter spike.

Speaks just enough HTTP/1.1 to exercise streaming, a slow body, a connection
dropped after the request is read, a short body with a lying Content-Length,
and TLS. Does not print request headers or bodies.
"""

from __future__ import annotations

import argparse
import json
import socket
import ssl
import threading
import time


class State:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.current = 0
        self.peak = 0
        self.total = 0
        self.hits: dict[str, int] = {}

    def enter(self, path: str) -> None:
        with self.lock:
            self.current += 1
            self.total += 1
            if self.current > self.peak:
                self.peak = self.current
            self.hits[path] = self.hits.get(path, 0) + 1

    def leave(self) -> None:
        with self.lock:
            self.current -= 1

    def snapshot(self) -> dict:
        with self.lock:
            return {
                "current": self.current,
                "peak": self.peak,
                "total": self.total,
                "hits": dict(self.hits),
            }


def read_request(conn: socket.socket) -> tuple[str, str, bytes] | None:
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = conn.recv(4096)
        if not chunk:
            return None
        data += chunk
        if len(data) > 2_000_000:
            return None
    head, _, rest = data.partition(b"\r\n\r\n")
    lines = head.decode("iso-8859-1", "replace").split("\r\n")
    if not lines or not lines[0]:
        return None
    parts = lines[0].split(" ")
    if len(parts) < 2:
        return None
    method, target = parts[0], parts[1]
    path = target.split("?", 1)[0]
    length = 0
    for line in lines[1:]:
        if line.lower().startswith("content-length:"):
            length = int(line.split(":", 1)[1].strip())
    while len(rest) < length:
        chunk = conn.recv(4096)
        if not chunk:
            break
        rest += chunk
    return method, path, rest[:length]


def send_all(conn: socket.socket, payload: bytes) -> None:
    conn.sendall(payload)


def respond(conn: socket.socket, status: int, body: bytes, content_type: str, extra: str = "") -> None:
    head = (
        f"HTTP/1.1 {status} X\r\n"
        f"Content-Type: {content_type}\r\n"
        f"Content-Length: {len(body)}\r\n"
        "Connection: close\r\n"
        f"{extra}"
        "\r\n"
    )
    send_all(conn, head.encode("ascii") + body)


def write_chunk(conn: socket.socket, payload: bytes) -> None:
    send_all(conn, f"{len(payload):x}\r\n".encode("ascii") + payload + b"\r\n")


def start_chunked(conn: socket.socket, status: int, content_type: str) -> None:
    head = (
        f"HTTP/1.1 {status} X\r\n"
        f"Content-Type: {content_type}\r\n"
        "Transfer-Encoding: chunked\r\n"
        "Cache-Control: no-cache\r\n"
        "Connection: close\r\n"
        "\r\n"
    )
    send_all(conn, head.encode("ascii"))


def sse(text: str) -> bytes:
    payload = json.dumps({"choices": [{"index": 0, "delta": {"content": text}}]})
    return f"data: {payload}\n\n".encode("utf-8")


def handle(conn: socket.socket, state: State) -> None:
    entered = False
    try:
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        conn.settimeout(5)
        req = read_request(conn)
        if req is None:
            return
        _method, path, body = req
        state.enter(path)
        entered = True
        if path == "/drop":
            return
        if path == "/partial":
            event = sse("partial")
            head = (
                "HTTP/1.1 200 X\r\n"
                "Content-Type: text/event-stream\r\n"
                "Content-Length: 1000\r\n"
                "Connection: close\r\n"
                "\r\n"
            )
            send_all(conn, head.encode("ascii") + event)
            return
        if path == "/hold":
            time.sleep(5)
            respond(conn, 200, b'{"held":true}', "application/json")
            return
        if path == "/error":
            respond(conn, 500, b'{"error":"nope"}', "application/json")
            return
        if path == "/stats":
            respond(conn, 200, json.dumps(state.snapshot()).encode("utf-8"), "application/json")
            return
        if path == "/echo":
            delay_ms = 0
            if body:
                try:
                    delay_ms = int(json.loads(body.decode("utf-8")).get("delay_ms") or 0)
                except (ValueError, TypeError, json.JSONDecodeError):
                    delay_ms = 0
            if delay_ms > 0:
                time.sleep(delay_ms / 1000.0)
            # Fixed body. The cookie is a bait value tests check does not reach logs.
            respond(
                conn,
                200,
                b'{"ok":true}',
                "application/json",
                "Set-Cookie: session=super-secret-token-xyz\r\n",
            )
            return
        if path == "/slow":
            start_chunked(conn, 200, "text/event-stream")
            for i in range(4):
                time.sleep(0.25)
                write_chunk(conn, sse(str(i)))
            write_chunk(conn, b"data: [DONE]\n\n")
            send_all(conn, b"0\r\n\r\n")
            return
        if path == "/v1/chat/completions":
            spec = {}
            if body:
                try:
                    spec = json.loads(body.decode("utf-8"))
                except json.JSONDecodeError:
                    spec = {}
            chunks = spec.get("chunks") or ["Hello", " ", "world"]
            delay_ms = int(spec.get("delay_ms") or 0)
            start_chunked(conn, 200, "text/event-stream")
            for text in chunks:
                if delay_ms > 0:
                    time.sleep(delay_ms / 1000.0)
                write_chunk(conn, sse(str(text)))
            write_chunk(conn, b"data: [DONE]\n\n")
            send_all(conn, b"0\r\n\r\n")
            return
        respond(conn, 404, b'{"error":"not found"}', "application/json")
    except (BrokenPipeError, ConnectionResetError, socket.timeout, ssl.SSLError, OSError):
        return
    finally:
        if entered:
            state.leave()
        try:
            conn.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        conn.close()


def serve(bind: str, port: int, state: State, tls: tuple[str, str] | None, label: str) -> None:
    raw = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    raw.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    raw.bind((bind, port))
    raw.listen(64)
    ctx = None
    if tls is not None:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        ctx.load_cert_chain(tls[0], tls[1])
        try:
            ctx.set_alpn_protocols(["http/1.1"])
        except NotImplementedError:
            pass
    actual = raw.getsockname()[1]
    print(f"{label} {actual}", flush=True)

    def loop() -> None:
        while True:
            try:
                conn, _addr = raw.accept()
            except OSError:
                return
            if ctx is not None:
                try:
                    conn = ctx.wrap_socket(conn, server_side=True)
                except ssl.SSLError:
                    conn.close()
                    continue
            threading.Thread(target=handle, args=(conn, state), daemon=True).start()

    threading.Thread(target=loop, daemon=True).start()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bind", default="127.0.0.1")
    parser.add_argument("--bad-cert")
    parser.add_argument("--bad-key")
    parser.add_argument("--good-cert")
    parser.add_argument("--good-key")
    args = parser.parse_args()
    state = State()
    import os

    print(f"PID {os.getpid()}", flush=True)
    serve(args.bind, 0, state, None, "HTTP")
    if args.bad_cert and args.bad_key:
        serve(args.bind, 0, state, (args.bad_cert, args.bad_key), "HTTPS_BAD")
    if args.good_cert and args.good_key:
        serve(args.bind, 0, state, (args.good_cert, args.good_key), "HTTPS_GOOD")
    print("READY", flush=True)
    try:
        threading.Event().wait()
    except KeyboardInterrupt:
        return


if __name__ == "__main__":
    main()
