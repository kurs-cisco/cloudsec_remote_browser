"""
TURN relay probe — run inside the worker Docker image to verify
that aiortc can gather relay candidates from the production TURN server.

Usage:
  docker run --rm -e TURN_URL=turn:turn.rbi.agenticisolation.com:3478?transport=udp \
    -e TURN_USERNAME=<hmac-username> -e TURN_PASSWORD=<hmac-credential> \
    <worker-image> python worker/turn_probe.py

Or with multiple URLs:
  -e TURN_URLS=turn:host:3478?transport=udp,turn:host:3478?transport=tcp

Exit code 0 = relay candidates gathered successfully.
Exit code 1 = no relay candidates (the problem we're debugging).
"""

import asyncio
import logging
import os
import sys
import urllib.parse

from aiortc import (
    RTCConfiguration,
    RTCIceServer,
    RTCPeerConnection,
    RTCSessionDescription,
)
from aiortc.sdp import candidate_to_sdp
from aioice import turn as aioice_turn


def log(*parts):
    print("[turn-probe]", *parts, flush=True)


def extract_candidate_type(candidate_sdp: str) -> str:
    fields = candidate_sdp.split()
    try:
        typ_index = fields.index("typ")
    except ValueError:
        return "unknown"
    if typ_index + 1 >= len(fields):
        return "unknown"
    return fields[typ_index + 1]


def collect_candidates_from_sdp(sdp: str):
    candidates = []
    for line in (sdp or "").splitlines():
        if not line.startswith("a=candidate:"):
            continue
        candidate_sdp = line[len("a="):]
        candidates.append(
            {
                "candidate": candidate_sdp,
                "type": extract_candidate_type(candidate_sdp),
            }
        )
    return candidates


def parse_turn_url(url: str):
    normalized = url
    if url.startswith("turn:") and not url.startswith("turn://"):
        normalized = "turn://" + url[len("turn:"):]
    elif url.startswith("turns:") and not url.startswith("turns://"):
        normalized = "turns://" + url[len("turns:"):]
    parsed = urllib.parse.urlparse(normalized)
    host = parsed.hostname
    port = parsed.port or 3478
    transport = urllib.parse.parse_qs(parsed.query).get("transport", ["udp"])[0]
    ssl = parsed.scheme == "turns"
    if not host:
        raise ValueError(f"TURN URL has no host: {url}")
    return host, port, transport, ssl


async def direct_turn_probe(url: str, username: str, password: str):
    host, port, transport, ssl_enabled = parse_turn_url(url)
    protocol = None
    transport_obj = None
    try:
        transport_obj, protocol = await aioice_turn.create_turn_endpoint(
            asyncio.DatagramProtocol,
            server_addr=(host, port),
            username=username,
            password=password,
            ssl=ssl_enabled,
            transport=transport,
        )
        relay = transport_obj.get_extra_info("sockname")
        related = transport_obj.get_extra_info("related_address")
        log(
            "direct-turn-success",
            f"url={url}",
            f"relay={relay}",
            f"related={related}",
        )
        return True
    except Exception as err:
        details = {
            "error_type": err.__class__.__name__,
            "error_repr": repr(err),
        }
        response = getattr(err, "response", None)
        if response is not None:
            details["response_class"] = getattr(response, "message_class", None)
            details["response_method"] = getattr(response, "message_method", None)
            details["response_attributes"] = getattr(response, "attributes", None)
        log("direct-turn-failure", f"url={url}", details)
        return False
    finally:
        if transport_obj is not None:
            transport_obj.close()


async def probe():
    if os.environ.get("TURN_PROBE_DEBUG", "0") == "1":
        logging.basicConfig(level=logging.DEBUG)
        logging.getLogger("aioice").setLevel(logging.DEBUG)
        logging.getLogger("aiortc").setLevel(logging.DEBUG)

    turn_url = os.environ.get("TURN_URL", "").strip()
    turn_urls_raw = os.environ.get("TURN_URLS", "").strip()
    username = os.environ.get("TURN_USERNAME", "").strip()
    password = os.environ.get("TURN_PASSWORD", "").strip()

    urls = []
    if turn_urls_raw:
        urls = [u.strip() for u in turn_urls_raw.split(",") if u.strip()]
    elif turn_url:
        urls = [turn_url]

    if not urls:
        log("ERROR: set TURN_URL or TURN_URLS env var")
        return False

    if not username or not password:
        log("ERROR: set TURN_USERNAME and TURN_PASSWORD env vars")
        return False

    log(f"urls={urls}")
    log(f"username={username[:12]}...")

    # Build individual RTCIceServer per URL (the Phase 2 fix)
    ice_servers = []
    for url in urls:
        if url.startswith("turn:") or url.startswith("turns:"):
            ice_servers.append(
                RTCIceServer(urls=[url], username=username, credential=password)
            )
        elif url.startswith("stun:") or url.startswith("stuns:"):
            ice_servers.append(RTCIceServer(urls=[url]))
        else:
            log(f"SKIP unknown URL scheme: {url}")

    log(f"ice_servers={len(ice_servers)}")

    for url in urls:
        if url.startswith("turn:") or url.startswith("turns:"):
            await direct_turn_probe(url, username, password)
            break

    gathering_complete = asyncio.Event()
    candidates_by_type = {}

    pc = RTCPeerConnection(
        configuration=RTCConfiguration(iceServers=ice_servers)
    )

    @pc.on("icecandidate")
    async def on_icecandidate(candidate):
        if candidate is None:
            log("ice-gathering-complete")
            gathering_complete.set()
            return

        sdp = candidate_to_sdp(candidate)
        ctype = getattr(candidate, "type", "") or "unknown"
        proto = getattr(candidate, "protocol", "?")
        host = getattr(candidate, "host", "?")
        port = getattr(candidate, "port", "?")
        log(f"candidate type={ctype} protocol={proto} address={host}:{port}")
        candidates_by_type.setdefault(ctype, []).append(sdp)

    @pc.on("icegatheringstatechange")
    async def on_gathering_state():
        state = pc.iceGatheringState
        log(f"gathering-state={state}")
        if state == "complete":
            gathering_complete.set()

    # Create a data channel to force ICE gathering
    pc.createDataChannel("probe")

    offer = await pc.createOffer()
    await pc.setLocalDescription(offer)

    log("waiting for ICE gathering (timeout 15s)...")
    try:
        await asyncio.wait_for(gathering_complete.wait(), timeout=15)
    except asyncio.TimeoutError:
        log("TIMEOUT: ICE gathering did not complete in 15s")

    try:
        transport = pc.sctp.transport.transport
        gatherer = transport.iceGatherer
        local_candidates = gatherer.getLocalCandidates()
        log(f"internal-local-candidates={len(local_candidates)}")
        for candidate in local_candidates:
            log(
                "internal-candidate",
                f"type={getattr(candidate, 'type', 'unknown')}",
                f"protocol={getattr(candidate, 'protocol', '?')}",
                f"address={getattr(candidate, 'ip', '?')}:{getattr(candidate, 'port', '?')}",
            )
    except Exception as err:
        log(f"failed-to-read-internal-candidates={err!r}")

    if pc.localDescription and pc.localDescription.sdp:
        sdp_candidates = collect_candidates_from_sdp(pc.localDescription.sdp)
        if sdp_candidates:
            log(f"sdp-candidates={len(sdp_candidates)}")
        for item in sdp_candidates:
            ctype = item["type"] or "unknown"
            if item["candidate"] not in candidates_by_type.get(ctype, []):
                candidates_by_type.setdefault(ctype, []).append(item["candidate"])
                log(f"sdp-candidate type={ctype}")

    await pc.close()

    log("--- results ---")
    total = 0
    for ctype, cands in sorted(candidates_by_type.items()):
        log(f"  {ctype}: {len(cands)}")
        total += len(cands)
    log(f"  total: {total}")

    relay_count = len(candidates_by_type.get("relay", []))
    if relay_count > 0:
        log(f"SUCCESS: {relay_count} relay candidate(s) gathered")
        return True
    else:
        log("FAILURE: no relay candidates gathered")
        if candidates_by_type:
            log("  (got host/srflx but no relay — TURN auth or connectivity issue)")
        else:
            log("  (no candidates at all — network or config issue)")
        return False


if __name__ == "__main__":
    success = asyncio.run(probe())
    sys.exit(0 if success else 1)
