#!/usr/bin/env python3
"""A WebDAV server, for checking the remote library against something real.

The same reasoning as the party harness: the parsers in this port are tested
against fixtures built in the shape of the wire format, and a fixture cannot
tell you that the client and the server disagree about a header. So this serves
real PROPFIND multistatus responses, real byte ranges, and a real 401, and the
deliberate awkwardnesses a share actually contains:

  * a name with a space and one with a non-ASCII character
  * a root-relative href and a relative one alongside an absolute one
  * a picture on *another host* in the listing, which is the case the
    credential rule exists for
  * a file with no parent folder, and a file that is not audio

Usage: webdav-fixture.py [port] [root]
Credentials: listener / correct-horse
Bound on all interfaces, because one of the cases needs two *names* for this
same server — the share is reached as `localhost`, one entry in the listing
points at `127.0.0.1`, and the difference between those two host strings is
the whole of the credential rule.
"""

import base64
import hashlib
import html
import os
import re
import struct
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import quote, unquote

USER, PASSWORD = "listener", "correct-horse"
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8081
ROOT = sys.argv[2] if len(sys.argv) > 2 else "/tmp/bitchord-webdav"

REQUEST_LOG = "/tmp/bitchord-webdav-requests.log"
_lock = threading.Lock()

JPEG = bytes([0xFF, 0xD8, 0xFF, 0xE0]) + b"filed-cover" + bytes(200)
EMBEDDED = bytes([0xFF, 0xD8, 0xFF, 0xE0]) + b"embedded-cover" + bytes(300)


def flac_with_cover(picture: bytes) -> bytes:
    """A FLAC whose only metadata block is a PICTURE holding `picture`.

    Written byte by byte in the order a tagger writes, because the point of the
    fixture is that the parser reads a real tag rather than bytes that resemble
    one.
    """
    mime = b"image/jpeg"
    body = struct.pack(">I", 3)                      # front cover
    body += struct.pack(">I", len(mime)) + mime
    body += struct.pack(">I", 0)                     # no description
    body += struct.pack(">IIII", 600, 600, 24, 0)    # w, h, depth, colours
    body += struct.pack(">I", len(picture)) + picture
    block = bytes([0x86]) + len(body).to_bytes(3, "big") + body
    return b"fLaC" + block + bytes([0x81]) + (4).to_bytes(3, "big") + b"\x00\x00\x00\x00"


def build_tree() -> None:
    if os.path.isdir(ROOT):
        return
    album = os.path.join(ROOT, "Music", "Pink Floyd", "The Dark Side of the Moon")
    os.makedirs(album)
    with open(os.path.join(ROOT, "Music", "Björk - Jóga.flac"), "wb") as f:
        f.write(flac_with_cover(EMBEDDED))
    with open(os.path.join(album, "01 - Time.flac"), "wb") as f:
        f.write(flac_with_cover(EMBEDDED))
    with open(os.path.join(album, "cover.jpg"), "wb") as f:
        f.write(JPEG)
    # The picture a download manager leaves behind, which must lose to cover.jpg.
    with open(os.path.join(album, "IMG_1234.jpg"), "wb") as f:
        f.write(JPEG[:-1])
    with open(os.path.join(album, "02 - Money.txt"), "wb") as f:
        f.write(b"not audio")
    # A picture in the share's root, which belongs to the file the listing below
    # points at another host. Fetching it must not carry the share's credential,
    # and this server requires one — so the refusal is the proof.
    with open(os.path.join(ROOT, "Music", "foreign.jpg"), "wb") as f:
        f.write(JPEG + b"foreign")
    print("fixtures:", {p: os.path.getsize(os.path.join(dp, p))
                        for dp, _, fs in os.walk(ROOT) for p in fs})


def relative(path: str) -> str:
    return "/" + os.path.relpath(path, ROOT).replace(os.sep, "/")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "bitchord-fixture/1"

    def log_message(self, *args):
        pass

    def record(self, note: str) -> None:
        with _lock:
            with open(REQUEST_LOG, "a") as f:
                f.write(f"{self.command} {self.path} {note}\n")

    def authorized(self) -> bool:
        header = self.headers.get("Authorization", "")
        if not header.startswith("Basic "):
            return False
        try:
            decoded = base64.b64decode(header[6:]).decode()
        except Exception:
            return False
        return decoded == f"{USER}:{PASSWORD}"

    def deny(self) -> None:
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="bitchord"')
        self.send_header("Content-Length", "0")
        self.end_headers()

    def refuse(self, note: str) -> None:
        self.record(note)
        self.send_response(403)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_PROPFIND(self):  # noqa: N802
        if not self.authorized():
            self.record("401")
            return self.deny()
        self.record("propfind")
        depth = self.headers.get("Depth", "1")
        path = self.translate()
        if not os.path.isdir(path):
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        entries = [self.response_for(path, collection=True)]
        if depth != "0":
            for name in sorted(os.listdir(path)):
                child = os.path.join(path, name)
                entries.append(self.response_for(child, collection=os.path.isdir(child)))
        body = ("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
                "<d:multistatus xmlns:d=\"DAV:\">\n" + "\n".join(entries) + "\n</d:multistatus>\n")
        self.send_response(207)
        self.send_header("Content-Type", 'application/xml; charset="utf-8"')
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body.encode())

    def response_for(self, path: str, collection: bool) -> str:
        name = os.path.basename(path) or "/"
        href = quote(relative(path))
        # Three href shapes in one listing, because real servers send all three
        # and a client that only handles the RFC's example reads a share as empty.
        # All three are escaped the way a real server escapes them — a client that
        # then shows `BjÃ¶rk` has a decoder bug, and that is the point.
        if name == "01 - Time.flac":
            href = quote(os.path.basename(path))            # relative to the directory
        elif "Jóga" in name:
            # Another *host*, by name, pointing at this same server. `localhost` and
            # `127.0.0.1` are the same machine and different hosts as far as a
            # credential rule is concerned, which makes this the one case where the
            # rule can be observed rather than argued about: the server below demands
            # a password, so a fetch that arrives without one is a refused fetch.
            href = "http://127.0.0.1:8081" + href
        resourcetype = "<d:collection/>" if collection else ""
        content_type = "" if collection else "<d:getcontenttype>application/octet-stream</d:getcontenttype>"
        return (
            "  <d:response>\n"
            f"    <d:href>{html.escape(href)}</d:href>\n"
            "    <d:propstat>\n"
            "      <d:prop>\n"
            f"        <d:displayname>{html.escape(name)}</d:displayname>\n"
            f"        <d:resourcetype>{resourcetype}</d:resourcetype>\n"
            f"        {content_type}\n"
            "      </d:prop>\n"
            "      <d:status>HTTP/1.1 200 OK</d:status>\n"
            "    </d:propstat>\n"
            "  </d:response>"
        )

    def translate(self) -> str:
        # A server decodes the path it is asked about; one that did not would 404 on
        # every folder with a space in its name, which is every folder.
        return os.path.join(ROOT, unquote(self.path.split("?")[0]).lstrip("/"))

    def do_HEAD(self):  # noqa: N802
        if not self.authorized():
            self.record("401")
            return self.deny()
        path = self.translate()
        self.record("head")
        if not os.path.isfile(path):
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Length", str(os.path.getsize(path)))
        self.end_headers()

    def do_GET(self):  # noqa: N802
        if not self.authorized():
            self.record("401")
            return self.deny()
        path = self.translate()
        self.record("get")
        if not os.path.isfile(path):
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        with open(path, "rb") as f:
            data = f.read()
        total = len(data)
        span = self.headers.get("Range", "")
        match = re.match(r"bytes=(\d+)-(\d*)", span)
        if match:
            start = int(match.group(1))
            end = int(match.group(2)) if match.group(2) else total - 1
            end = min(end, total - 1)
            if start >= total:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{total}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            chunk = data[start:end + 1]
            self.send_response(206)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Range", f"bytes {start}-{end}/{total}")
            self.send_header("Content-Length", str(len(chunk)))
            self.end_headers()
            self.wfile.write(chunk)
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(total))
        self.end_headers()
        self.wfile.write(data)


if __name__ == "__main__":
    build_tree()
    open(REQUEST_LOG, "w").close()
    print(f"sha256 embedded={hashlib.sha256(EMBEDDED).hexdigest()[:16]} filed={hashlib.sha256(JPEG).hexdigest()[:16]}")
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
