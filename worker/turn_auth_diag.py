"""
TURN authentication diagnostic — isolates the exact failure in the
aioice ↔ coturn authentication handshake.

Performs the TURN allocation manually (raw STUN messages over UDP)
using the exact same logic as aioice, with verbose output at each step.

Usage:
  TURN_SHARED_SECRET=<secret> python worker/turn_auth_diag.py
  # or pass pre-computed credentials:
  TURN_USERNAME=<ts:user> TURN_PASSWORD=<base64> \
    TURN_HOST=turn.rbi.agenticisolation.com TURN_PORT=3478 \
    python worker/turn_auth_diag.py
"""

import asyncio
import base64
import hashlib
import hmac
import os
import socket
import struct
import sys
import time

# ---------------------------------------------------------------------------
# STUN constants (mirrors aioice/stun.py)
# ---------------------------------------------------------------------------
COOKIE = 0x2112A442
HEADER_LENGTH = 20
INTEGRITY_LENGTH = 24
FINGERPRINT_LENGTH = 8
FINGERPRINT_XOR = 0x5354554E
UDP_TRANSPORT = 0x11000000

ATTR_USERNAME = 0x0006
ATTR_MESSAGE_INTEGRITY = 0x0008
ATTR_ERROR_CODE = 0x0009
ATTR_LIFETIME = 0x000D
ATTR_REALM = 0x0014
ATTR_NONCE = 0x0015
ATTR_XOR_RELAYED_ADDRESS = 0x0016
ATTR_REQUESTED_TRANSPORT = 0x0019
ATTR_FINGERPRINT = 0x8028

METHOD_ALLOCATE = 0x0003
CLASS_REQUEST = 0x0000
CLASS_RESPONSE = 0x0100
CLASS_ERROR = 0x0110


def log(tag, *parts):
    print(f"[diag][{tag}]", *parts, flush=True)


def fingerprint(value):
    if isinstance(value, str):
        value = value.encode("utf8")
    return hashlib.sha256(value).hexdigest()[:16]


def random_txn_id():
    return os.urandom(12)


def padding_length(n):
    rest = n % 4
    return 0 if rest == 0 else (4 - rest)


# ---------------------------------------------------------------------------
# STUN message building (mirrors aioice)
# ---------------------------------------------------------------------------
def build_stun_message(method, cls, txn_id, attrs_list):
    """
    Build a STUN message.
    attrs_list: list of (attr_type, attr_value_bytes)
    """
    body = b""
    for attr_type, attr_value in attrs_list:
        attr_len = len(attr_value)
        pad = padding_length(attr_len)
        body += struct.pack("!HH", attr_type, attr_len) + attr_value + bytes(pad)

    msg_type = method | cls
    header = struct.pack("!HHI12s", msg_type, len(body), COOKIE, txn_id)
    return header + body


def set_body_length(data, length):
    return data[0:2] + struct.pack("!H", length) + data[4:]


def compute_message_integrity(data, key):
    """HMAC-SHA1 over message with body length adjusted for MESSAGE-INTEGRITY."""
    check_data = set_body_length(data, len(data) - HEADER_LENGTH + INTEGRITY_LENGTH)
    return hmac.new(key, check_data, "sha1").digest()


def compute_fingerprint(data):
    """CRC32 XOR'd with magic, over message with body length adjusted for FINGERPRINT."""
    import binascii
    check_data = set_body_length(data, len(data) - HEADER_LENGTH + FINGERPRINT_LENGTH)
    return binascii.crc32(check_data) ^ FINGERPRINT_XOR


def make_integrity_key(username, realm, password):
    """MD5(username:realm:password) — RFC 5389 long-term credential."""
    raw = ":".join([username, realm, password])
    key = hashlib.md5(raw.encode("utf8")).digest()
    return key, raw


def pack_string(s):
    return s.encode("utf8")


def pack_unsigned(v):
    return struct.pack("!I", v)


# ---------------------------------------------------------------------------
# STUN message parsing (minimal)
# ---------------------------------------------------------------------------
def parse_stun_response(data):
    if len(data) < HEADER_LENGTH:
        return None
    msg_type, length, cookie, txn_id = struct.unpack("!HHI12s", data[:HEADER_LENGTH])
    method = msg_type & 0x3EEF
    cls = msg_type & 0x0110
    attrs = {}
    pos = HEADER_LENGTH
    while pos + 4 <= len(data):
        attr_type, attr_len = struct.unpack("!HH", data[pos:pos + 4])
        attr_val = data[pos + 4:pos + 4 + attr_len]
        pad = padding_length(attr_len)
        attrs[attr_type] = attr_val
        pos += 4 + attr_len + pad
    return {
        "method": method,
        "class": cls,
        "txn_id": txn_id,
        "attrs": attrs,
    }


def decode_error_code(val):
    if len(val) < 4:
        return None, ""
    _, code_high, code_low = struct.unpack("!HBB", val[:4])
    reason = val[4:].decode("utf8", errors="replace")
    return code_high * 100 + code_low, reason


def decode_string(val):
    return val.decode("utf8", errors="replace")


# ---------------------------------------------------------------------------
# Credential generation (mirrors turn-credentials.js / generate-turn-creds.sh)
# ---------------------------------------------------------------------------
def generate_turn_credentials(secret, role="worker", session_id=None, ttl=300):
    if session_id is None:
        session_id = f"diag-{int(time.time())}"
    expires_at = int(time.time()) + ttl
    opaque_user = f"{role}.{session_id}"
    username = f"{expires_at}:{opaque_user}"
    credential = base64.b64encode(
        hmac.new(secret.encode("utf8"), username.encode("utf8"), "sha1").digest()
    ).decode("ascii")
    return username, credential


# ---------------------------------------------------------------------------
# Main diagnostic
# ---------------------------------------------------------------------------
async def run_diag():
    # --- Gather parameters ---
    secret = os.environ.get("TURN_SHARED_SECRET", "").strip()
    username = os.environ.get("TURN_USERNAME", "").strip()
    password = os.environ.get("TURN_PASSWORD", "").strip()
    host = os.environ.get("TURN_HOST", "turn.rbi.agenticisolation.com").strip()
    port = int(os.environ.get("TURN_PORT", "3478"))

    if not username and secret:
        username, password = generate_turn_credentials(secret)
        log("creds", f"Generated from secret: username={username}")
    elif not username:
        log("error", "Set TURN_SHARED_SECRET or (TURN_USERNAME + TURN_PASSWORD)")
        return False

    log("config", f"host={host} port={port}")
    log("config", f"username={username}")
    log("config", f"password=<redacted> len={len(password)} fp={fingerprint(password)}")

    # Verify password is valid base64
    try:
        password_raw = base64.b64decode(password)
        log("config", f"password_raw=<redacted> len={len(password_raw)} fp={fingerprint(password_raw)}")
    except Exception as e:
        log("warning", f"password is not valid base64: {e}")

    # --- Resolve DNS ---
    try:
        infos = socket.getaddrinfo(host, port, socket.AF_INET, socket.SOCK_DGRAM)
        resolved_addr = infos[0][4]  # (ip, port)
        log("dns", f"{host}:{port} -> {resolved_addr[0]}:{resolved_addr[1]}")
    except Exception as e:
        log("error", f"DNS resolution failed: {e}")
        return False

    # --- Create UDP socket ---
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(5)
    sock.connect(resolved_addr)
    local_addr = sock.getsockname()
    log("socket", f"local={local_addr[0]}:{local_addr[1]} -> remote={resolved_addr[0]}:{resolved_addr[1]}")

    # ========================================================================
    # Step 1: Send ALLOCATE without auth (expect 401)
    # ========================================================================
    txn_id_1 = random_txn_id()
    attrs_1 = [
        (ATTR_LIFETIME, pack_unsigned(600)),
        (ATTR_REQUESTED_TRANSPORT, pack_unsigned(UDP_TRANSPORT)),
    ]
    msg_1 = build_stun_message(METHOD_ALLOCATE, CLASS_REQUEST, txn_id_1, attrs_1)
    log("step1", f"Sending unauthenticated ALLOCATE ({len(msg_1)} bytes)")
    log("step1", f"txn_id={txn_id_1.hex()}")
    sock.send(msg_1)

    try:
        resp_data_1 = sock.recv(4096)
    except socket.timeout:
        log("step1", "TIMEOUT — no response from TURN server")
        sock.close()
        return False

    resp_1 = parse_stun_response(resp_data_1)
    if resp_1 is None:
        log("step1", f"Could not parse response ({len(resp_data_1)} bytes)")
        sock.close()
        return False

    cls_name = {CLASS_REQUEST: "REQUEST", CLASS_RESPONSE: "RESPONSE", CLASS_ERROR: "ERROR"}.get(resp_1["class"], f"0x{resp_1['class']:04x}")
    log("step1", f"Response: class={cls_name} method=0x{resp_1['method']:04x}")

    if resp_1["class"] != CLASS_ERROR:
        log("step1", "Expected 401 error, got non-error response. Unexpected.")
        sock.close()
        return False

    error_attr = resp_1["attrs"].get(ATTR_ERROR_CODE)
    if error_attr:
        code, reason = decode_error_code(error_attr)
        log("step1", f"Error: {code} {reason}")
    else:
        log("step1", "No ERROR-CODE attribute in response")
        sock.close()
        return False

    nonce = resp_1["attrs"].get(ATTR_NONCE)
    realm_bytes = resp_1["attrs"].get(ATTR_REALM)

    if nonce is None:
        log("step1", "No NONCE in 401 response — cannot authenticate")
        sock.close()
        return False
    if realm_bytes is None:
        log("step1", "No REALM in 401 response — cannot authenticate")
        sock.close()
        return False

    realm = decode_string(realm_bytes)
    log("step1", f"NONCE=<redacted> len={len(nonce)} fp={fingerprint(nonce)}")
    log("step1", f"REALM={realm!r}")

    # ========================================================================
    # Step 2: Compute integrity key (exactly as aioice does)
    # ========================================================================
    integrity_key, integrity_input = make_integrity_key(username, realm, password)
    log("step2", f"integrity_key input=<redacted> len={len(integrity_input)} fp={fingerprint(integrity_input)}")
    log("step2", f"integrity_key=<redacted> len={len(integrity_key)} fp={fingerprint(integrity_key)}")

    # Also compute what coturn would compute (for comparison)
    if secret:
        coturn_password = base64.b64encode(
            hmac.new(secret.encode("utf8"), username.encode("utf8"), "sha1").digest()
        ).decode("ascii")
        coturn_key_input = f"{username}:{realm}:{coturn_password}"
        coturn_key = hashlib.md5(coturn_key_input.encode("utf8")).digest()
        log("step2", f"coturn would compute password=<redacted> len={len(coturn_password)} fp={fingerprint(coturn_password)}")
        log("step2", f"coturn integrity_key input=<redacted> len={len(coturn_key_input)} fp={fingerprint(coturn_key_input)}")
        log("step2", f"coturn integrity_key=<redacted> len={len(coturn_key)} fp={fingerprint(coturn_key)}")
        if coturn_key == integrity_key:
            log("step2", "MATCH: client and server integrity keys are identical")
        else:
            log("step2", "MISMATCH: client and server integrity keys DIFFER!")
            log("step2", f"  client password fp={fingerprint(password)}")
            log("step2", f"  server password fp={fingerprint(coturn_password)}")
            log("step2", f"  passwords match: {password == coturn_password}")

    # ========================================================================
    # Step 3: Send authenticated ALLOCATE (mirrors aioice retry)
    # ========================================================================
    txn_id_2 = random_txn_id()

    # Build attributes in the same order as aioice:
    # LIFETIME, REQUESTED-TRANSPORT, USERNAME, NONCE, REALM
    # then MESSAGE-INTEGRITY and FINGERPRINT
    pre_integrity_attrs = [
        (ATTR_LIFETIME, pack_unsigned(600)),
        (ATTR_REQUESTED_TRANSPORT, pack_unsigned(UDP_TRANSPORT)),
        (ATTR_USERNAME, pack_string(username)),
        (ATTR_NONCE, nonce),  # raw bytes, exactly as received
        (ATTR_REALM, pack_string(realm)),
    ]

    # Build message without MESSAGE-INTEGRITY/FINGERPRINT first
    msg_no_integrity = build_stun_message(METHOD_ALLOCATE, CLASS_REQUEST, txn_id_2, pre_integrity_attrs)

    # Compute MESSAGE-INTEGRITY
    mi_value = compute_message_integrity(msg_no_integrity, integrity_key)
    log("step3", f"MESSAGE-INTEGRITY=<redacted> len={len(mi_value)} fp={fingerprint(mi_value)}")

    # Add MESSAGE-INTEGRITY attribute
    all_attrs = pre_integrity_attrs + [
        (ATTR_MESSAGE_INTEGRITY, mi_value),
    ]
    msg_with_integrity = build_stun_message(METHOD_ALLOCATE, CLASS_REQUEST, txn_id_2, all_attrs)

    # Compute FINGERPRINT
    fp_value = compute_fingerprint(msg_with_integrity)
    log("step3", f"FINGERPRINT=0x{fp_value:08x}")

    # Add FINGERPRINT attribute
    final_attrs = all_attrs + [
        (ATTR_FINGERPRINT, struct.pack("!I", fp_value)),
    ]
    msg_2 = build_stun_message(METHOD_ALLOCATE, CLASS_REQUEST, txn_id_2, final_attrs)

    log("step3", f"Sending authenticated ALLOCATE ({len(msg_2)} bytes)")
    log("step3", f"txn_id={txn_id_2.hex()}")
    log("step3", f"USERNAME attr={username!r}")
    log("step3", f"NONCE attr=<redacted> len={len(nonce)} fp={fingerprint(nonce)}")
    log("step3", f"REALM attr={realm!r}")
    log("step3", f"Full message=<redacted> len={len(msg_2)} fp={fingerprint(msg_2)}")

    sock.send(msg_2)

    try:
        resp_data_2 = sock.recv(4096)
    except socket.timeout:
        log("step3", "TIMEOUT — no response to authenticated ALLOCATE")
        sock.close()
        return False

    resp_2 = parse_stun_response(resp_data_2)
    if resp_2 is None:
        log("step3", f"Could not parse response ({len(resp_data_2)} bytes)")
        sock.close()
        return False

    cls_name_2 = {CLASS_REQUEST: "REQUEST", CLASS_RESPONSE: "RESPONSE", CLASS_ERROR: "ERROR"}.get(resp_2["class"], f"0x{resp_2['class']:04x}")
    log("step3", f"Response: class={cls_name_2} method=0x{resp_2['method']:04x}")
    log("step3", f"Response=<redacted> len={len(resp_data_2)} fp={fingerprint(resp_data_2)}")

    if resp_2["class"] == CLASS_RESPONSE:
        log("step3", "SUCCESS — TURN allocation created!")
        if ATTR_XOR_RELAYED_ADDRESS in resp_2["attrs"]:
            log("step3", f"Relayed address attr (raw): {resp_2['attrs'][ATTR_XOR_RELAYED_ADDRESS].hex()}")
        if ATTR_LIFETIME in resp_2["attrs"]:
            lt = struct.unpack("!I", resp_2["attrs"][ATTR_LIFETIME])[0]
            log("step3", f"Lifetime: {lt}s")
        sock.close()
        return True
    elif resp_2["class"] == CLASS_ERROR:
        error_attr_2 = resp_2["attrs"].get(ATTR_ERROR_CODE)
        if error_attr_2:
            code_2, reason_2 = decode_error_code(error_attr_2)
            log("step3", f"FAILED: {code_2} {reason_2}")
        else:
            log("step3", "FAILED with unknown error (no ERROR-CODE)")

        # Log all attributes from the error response
        for attr_type, attr_val in resp_2["attrs"].items():
            name = {
                ATTR_ERROR_CODE: "ERROR-CODE",
                ATTR_NONCE: "NONCE",
                ATTR_REALM: "REALM",
                ATTR_USERNAME: "USERNAME",
                ATTR_MESSAGE_INTEGRITY: "MESSAGE-INTEGRITY",
                ATTR_FINGERPRINT: "FINGERPRINT",
            }.get(attr_type, f"0x{attr_type:04x}")
            if attr_type == ATTR_REALM:
                log("step3", f"  {name}={decode_string(attr_val)!r}")
            elif attr_type == ATTR_NONCE:
                log("step3", f"  {name}=<redacted> len={len(attr_val)} fp={fingerprint(attr_val)}")
            else:
                log("step3", f"  {name}=<redacted> len={len(attr_val)} fp={fingerprint(attr_val)}")

        sock.close()
        return False

    sock.close()
    return False


# ========================================================================
# Step 4: Also test via aioice (if available) to compare behavior
# ========================================================================
async def test_aioice_direct():
    """Run the same test through aioice to confirm it fails."""
    try:
        from aioice import turn as aioice_turn
    except ImportError:
        log("aioice", "aioice not installed, skipping aioice test")
        return

    import logging
    logging.basicConfig(level=logging.DEBUG)
    logging.getLogger("aioice").setLevel(logging.DEBUG)

    username = os.environ.get("TURN_USERNAME", "").strip()
    password = os.environ.get("TURN_PASSWORD", "").strip()
    host = os.environ.get("TURN_HOST", "turn.rbi.agenticisolation.com").strip()
    port = int(os.environ.get("TURN_PORT", "3478"))

    if not username:
        secret = os.environ.get("TURN_SHARED_SECRET", "").strip()
        if secret:
            username, password = generate_turn_credentials(secret)

    if not username:
        log("aioice", "No credentials, skipping aioice test")
        return

    log("aioice", f"Testing aioice with username={username} host={host}:{port}")
    try:
        transport_obj, protocol = await aioice_turn.create_turn_endpoint(
            asyncio.DatagramProtocol,
            server_addr=(host, port),
            username=username,
            password=password,
            ssl=False,
            transport="udp",
        )
        relay = transport_obj.get_extra_info("sockname")
        log("aioice", f"SUCCESS: relay={relay}")
        transport_obj.close()
    except Exception as err:
        log("aioice", f"FAILED: {err!r}")
        response = getattr(err, "response", None)
        if response:
            log("aioice", f"  response class={response.message_class}")
            log("aioice", f"  response attrs={response.attributes}")


if __name__ == "__main__":
    log("start", "TURN authentication diagnostic")
    log("start", f"Python {sys.version}")

    loop = asyncio.new_event_loop()

    # Run raw diagnostic
    log("phase", "=== Phase 1: Raw STUN diagnostic ===")
    raw_ok = loop.run_until_complete(run_diag())

    # Run aioice test for comparison
    if os.environ.get("SKIP_AIOICE_TEST", "0") != "1":
        log("phase", "=== Phase 2: aioice comparison test ===")
        loop.run_until_complete(test_aioice_direct())

    log("done", f"Raw test result: {'PASS' if raw_ok else 'FAIL'}")
