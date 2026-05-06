#!/usr/bin/env python3
"""EKS/Kata worker egress proof using only Python stdlib."""

import base64
import json
import os
import socket
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request


TIMEOUT_SECONDS = float(os.environ.get("EGRESS_PROOF_TIMEOUT_SECONDS", "6"))
TLS_CONTEXT = ssl._create_unverified_context()
STUN_MAGIC_COOKIE = b"\x21\x12\xa4\x42"

failures = []


class ProbeError(Exception):
    pass


def env(name, default=""):
    return str(os.environ.get(name, default) or "").strip()


def first_env(*names):
    for name in names:
        value = env(name)
        if value:
            return value
    return ""


def split_csv(value):
    return [item.strip() for item in str(value or "").split(",") if item.strip()]


def emit(name, status, detail):
    print(
        json.dumps(
            {"proof": name, "status": status, "detail": str(detail)},
            sort_keys=True,
        ),
        flush=True,
    )


def record_failure(name, detail):
    failures.append({"proof": name, "detail": str(detail)})
    emit(name, "fail", detail)


def expect_success(name, probe):
    try:
        detail = probe()
    except Exception as exc:
        record_failure(name, f"{type(exc).__name__}: {exc}")
        return
    emit(name, "pass", detail)


def expect_blocked(name, probe):
    try:
        detail = probe()
    except Exception as exc:
        emit(name, "pass", f"blocked: {type(exc).__name__}: {exc}")
        return
    record_failure(name, f"unexpected direct success: {detail}")


def parse_host_port(value, default_port=None):
    value = str(value or "").strip()
    if not value:
        raise ProbeError("target is empty")

    parsed = urllib.parse.urlparse(value if "://" in value else f"//{value}")
    host = parsed.hostname
    port = parsed.port or default_port
    if not host or not port:
        raise ProbeError(f"target must include host and port: {value}")
    return host, int(port)


def http_fetch(url, proxy_url=None):
    handlers = [urllib.request.HTTPSHandler(context=TLS_CONTEXT)]
    if proxy_url:
        handlers.insert(
            0,
            urllib.request.ProxyHandler({"http": proxy_url, "https": proxy_url}),
        )
    else:
        handlers.insert(0, urllib.request.ProxyHandler({}))

    opener = urllib.request.build_opener(*handlers)
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "cloudsec-rbi-egress-proof/1.0"},
        method="GET",
    )
    try:
        with opener.open(request, timeout=TIMEOUT_SECONDS) as response:
            response.read(256)
            status = int(response.getcode())
            return status, f"http {status} {url}"
    except urllib.error.HTTPError as exc:
        exc.read(256)
        return int(exc.code), f"http {exc.code} {url}"


def http_success(url, proxy_url):
    status, detail = http_fetch(url, proxy_url=proxy_url)
    if status >= 400:
        raise ProbeError(detail)
    return detail


def proxy_deny(url, proxy_url):
    try:
        status, detail = http_fetch(url, proxy_url=proxy_url)
    except Exception as exc:
        return f"proxy denied or blocked: {type(exc).__name__}: {exc}"
    if status >= 400:
        return f"proxy denied: {detail}"
    raise ProbeError(f"proxy unexpectedly allowed internal URL: {detail}")


def tcp_connect(target, default_port=None):
    host, port = parse_host_port(target, default_port=default_port)
    with socket.create_connection((host, port), timeout=TIMEOUT_SECONDS):
        return f"connected {host}:{port}"


def build_host_header(host, port, scheme):
    default_port = 443 if scheme == "wss" else 80
    if port == default_port:
        return host
    return f"{host}:{port}"


def websocket_probe(url, connect_host=""):
    parsed = urllib.parse.urlparse(str(url or "").strip())
    if parsed.scheme not in ("ws", "wss"):
        raise ProbeError(f"expected ws/wss URL: {url}")
    if not parsed.hostname:
        raise ProbeError(f"websocket URL missing host: {url}")

    port = parsed.port or (443 if parsed.scheme == "wss" else 80)
    target_host = connect_host or parsed.hostname
    path = parsed.path or "/"
    if parsed.query:
        path = f"{path}?{parsed.query}"

    raw = socket.create_connection((target_host, port), timeout=TIMEOUT_SECONDS)
    try:
        raw.settimeout(TIMEOUT_SECONDS)
        if parsed.scheme == "wss":
            sock = TLS_CONTEXT.wrap_socket(raw, server_hostname=parsed.hostname)
        else:
            sock = raw
        try:
            ws_key = base64.b64encode(os.urandom(16)).decode("ascii")
            request = (
                f"GET {path} HTTP/1.1\r\n"
                f"Host: {build_host_header(parsed.hostname, port, parsed.scheme)}\r\n"
                "Connection: Upgrade\r\n"
                "Upgrade: websocket\r\n"
                f"Sec-WebSocket-Key: {ws_key}\r\n"
                "Sec-WebSocket-Version: 13\r\n"
                "\r\n"
            ).encode("ascii")
            sock.sendall(request)
            response = sock.recv(256)
            if not response.startswith(b"HTTP/"):
                raise ProbeError(f"non-HTTP response: {response[:32]!r}")
            status_line = response.split(b"\r\n", 1)[0].decode(
                "iso-8859-1",
                "replace",
            )
            return f"{status_line} from {parsed.hostname}:{port}"
        finally:
            sock.close()
    except Exception:
        raw.close()
        raise


def parse_turn_udp_target(worker_ice_urls):
    for item in split_csv(worker_ice_urls):
        parsed = urllib.parse.urlparse(item)
        if parsed.scheme not in ("turn", "turns"):
            continue
        query = urllib.parse.parse_qs(parsed.query)
        transport = query.get("transport", ["udp"])[0].lower()
        if transport != "udp":
            continue

        target = item.split("?", 1)[0]
        for prefix in ("turn:", "turns:"):
            if target.startswith(prefix):
                target = target[len(prefix) :]
                break
        host, port = parse_host_port(target, default_port=3478)
        return host, port

    raise ProbeError("WORKER_ICE_URLS does not contain a UDP TURN target")


def stun_udp_probe(worker_ice_urls):
    host, port = parse_turn_udp_target(worker_ice_urls)
    txid = os.urandom(12)
    request = b"\x00\x01\x00\x00" + STUN_MAGIC_COOKIE + txid
    last_error = None

    for family, socktype, proto, _, sockaddr in socket.getaddrinfo(
        host,
        port,
        type=socket.SOCK_DGRAM,
    ):
        if socktype != socket.SOCK_DGRAM:
            continue
        sock = socket.socket(family, socktype, proto)
        try:
            sock.settimeout(TIMEOUT_SECONDS)
            sock.sendto(request, sockaddr)
            response, _ = sock.recvfrom(1500)
            if len(response) < 20:
                raise ProbeError(f"short STUN response from {host}:{port}")
            if response[4:8] != STUN_MAGIC_COOKIE or response[8:20] != txid:
                raise ProbeError(f"invalid STUN response from {host}:{port}")
            message_type = int.from_bytes(response[0:2], "big")
            return f"stun response type=0x{message_type:04x} from {host}:{port}/udp"
        except Exception as exc:
            last_error = exc
        finally:
            sock.close()

    raise ProbeError(last_error or f"no UDP address for {host}:{port}")


def direct_redis_target():
    configured = env("EGRESS_PROOF_REDIS_TARGET")
    if configured:
        return configured
    redis_url = env("REDIS_URL")
    if redis_url:
        parsed = urllib.parse.urlparse(redis_url)
        default_port = 6380 if parsed.scheme == "rediss" else 6379
        host, port = parse_host_port(redis_url, default_port=default_port)
        return f"{host}:{port}"
    return "redis.cloudsec-rbi-control.svc.cluster.local:6379"


def main():
    proxy_url = first_env(
        "SWG_EGRESS_PROXY_URL",
        "HTTPS_PROXY",
        "HTTP_PROXY",
        "https_proxy",
        "http_proxy",
    )
    public_url = env("EGRESS_PROOF_PUBLIC_URL", "https://example.com/")
    metadata_url = env(
        "EGRESS_PROOF_METADATA_URL",
        "http://169.254.169.254/latest/meta-data/",
    )
    kube_api_target = env("EGRESS_PROOF_KUBE_API_TARGET", "kubernetes.default.svc:443")
    public_dns_target = env("EGRESS_PROOF_PUBLIC_DNS_TARGET", "8.8.8.8:53")
    internal_targets = split_csv(
        env(
            "EGRESS_PROOF_INTERNAL_TCP_TARGETS",
            "10.0.0.1:443,172.16.0.1:443,192.168.0.1:443",
        )
    )
    proxy_deny_urls = split_csv(
        env(
            "EGRESS_PROOF_PROXY_DENY_URLS",
            "http://169.254.169.254/latest/meta-data/,http://10.0.0.1/",
        )
    )
    control_wss_url = env("EGRESS_PROOF_CONTROL_WSS_URL") or env("POOL_WS_URL")
    control_connect_host = env("EGRESS_PROOF_CONTROL_WSS_CONNECT_HOST") or env(
        "POOL_WS_CONNECT_HOST"
    )
    media_wss_url = env("EGRESS_PROOF_MEDIA_GATEWAY_WSS_URL") or env("SIGNALING_URL")
    media_connect_host = env("EGRESS_PROOF_MEDIA_GATEWAY_CONNECT_HOST") or env(
        "SIGNALING_CONNECT_HOST"
    )
    worker_ice_urls = env("WORKER_ICE_URLS")

    expect_blocked("direct_public_https", lambda: http_fetch(public_url))
    if proxy_url:
        expect_success(
            "proxied_public_https",
            lambda: http_success(public_url, proxy_url),
        )
    else:
        record_failure("proxied_public_https", "missing SWG proxy URL")

    expect_blocked("direct_metadata_http", lambda: http_fetch(metadata_url))
    expect_blocked("direct_kube_api", lambda: tcp_connect(kube_api_target))
    expect_blocked("direct_redis", lambda: tcp_connect(direct_redis_target()))
    expect_blocked("direct_public_dns_8_8_8_8_53", lambda: tcp_connect(public_dns_target))
    for target in internal_targets:
        proof_name = "direct_internal_cidr_" + target.replace(".", "_").replace(":", "_")
        expect_blocked(proof_name, lambda target=target: tcp_connect(target))

    if proxy_url:
        for url in proxy_deny_urls:
            proof_name = (
                "proxied_internal_deny_"
                + urllib.parse.urlparse(url).netloc.replace(".", "_").replace(":", "_")
            )
            expect_success(proof_name, lambda url=url: proxy_deny(url, proxy_url))

    expect_success(
        "control_wss",
        lambda: websocket_probe(control_wss_url, connect_host=control_connect_host),
    )
    expect_success(
        "media_gateway_wss",
        lambda: websocket_probe(media_wss_url, connect_host=media_connect_host),
    )
    expect_success("turn_udp", lambda: stun_udp_probe(worker_ice_urls))

    if failures:
        emit("summary", "fail", failures)
        return 1
    emit("summary", "pass", "worker egress proof completed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
