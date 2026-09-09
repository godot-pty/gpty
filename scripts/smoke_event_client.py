#!/usr/bin/env python3
"""Minimal line-delimited JSON-RPC client for the gpty event socket.

Used by scripts/smoke-pane-api to cover subscribe/eventsPoll end-to-end.
The event socket has no auth (read-only observability fan-out).

Usage:
  smoke_event_client.py <socket_path> subscribe
  smoke_event_client.py <socket_path> eventsPoll <subscription_id>
"""
import json
import socket
import sys


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: smoke_event_client.py <socket> subscribe|eventsPoll [sub_id]", file=sys.stderr)
        return 2
    sock_path, method = sys.argv[1], sys.argv[2]
    params: dict = {}
    if method == "eventsPoll":
        if len(sys.argv) != 4:
            print("eventsPoll requires a subscription id", file=sys.stderr)
            return 2
        params = {"subscription_id": sys.argv[3], "limit": 64}
    payload = {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.connect(sock_path)
        s.sendall((json.dumps(payload) + "\n").encode())
        data = s.recv(65536)
    print(data.decode().strip())
    return 0


if __name__ == "__main__":
    sys.exit(main())
