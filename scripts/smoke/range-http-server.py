#!/usr/bin/env python3
"""Serve a folder over HTTP on 127.0.0.1 with byte ranges, for download journeys.

  range-http-server.py <folder> <port> [--rate BYTES_PER_SECOND]

--rate slows every response so a journey can cancel or stop the server
mid-download. Responses carry ETag and Last-Modified so URLSession can resume.
"""
import argparse
import email.utils
import http.server
import os
import pathlib
import time

parser = argparse.ArgumentParser()
parser.add_argument("folder")
parser.add_argument("port", type=int)
parser.add_argument("--rate", type=int, default=0)
args = parser.parse_args()
ROOT = pathlib.Path(args.folder).resolve()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *values):
        print(f"{self.command} {self.path} {self.headers.get('Range', '-')} -> " + fmt % values, flush=True)

    def do_HEAD(self):
        self.respond(send_body=False)

    def do_GET(self):
        self.respond(send_body=True)

    def respond(self, send_body):
        path = (ROOT / self.path.lstrip("/").split("?")[0]).resolve()
        if ROOT not in path.parents or not path.is_file():
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        size = path.stat().st_size
        mtime = path.stat().st_mtime
        etag = f'"{int(mtime)}-{size}"'
        start, end, status = 0, size - 1, 200
        wanted = self.headers.get("Range", "")
        if wanted.startswith("bytes="):
            first, _, last = wanted[6:].partition("-")
            start = int(first) if first else 0
            end = int(last) if last else size - 1
            status = 206
        if start >= size:
            self.send_response(416)
            self.send_header("Content-Range", f"bytes */{size}")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        length = end - start + 1
        self.send_response(status)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(length))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("ETag", etag)
        self.send_header("Last-Modified", email.utils.formatdate(mtime, usegmt=True))
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        if not send_body:
            return
        sent = 0
        with open(path, "rb") as source:
            source.seek(start)
            while sent < length:
                chunk = source.read(min(64 * 1024, length - sent))
                if not chunk:
                    break
                try:
                    self.wfile.write(chunk)
                except (BrokenPipeError, ConnectionResetError):
                    return
                sent += len(chunk)
                if args.rate:
                    time.sleep(len(chunk) / args.rate)


http.server.ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
