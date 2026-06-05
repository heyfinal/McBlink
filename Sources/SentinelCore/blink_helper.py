#!/usr/bin/env python3
"""McBlink Blink bridge — JSON CLI over blinkpy for SentinelCore.
Persistent auth via saved creds (no 2FA after first login)."""
import asyncio, os, json, sys, argparse
from aiohttp import ClientSession
from blinkpy.blinkpy import Blink
from blinkpy.auth import Auth, BlinkTwoFARequiredError

CREDS = os.environ.get("BLINK_CREDS",
    os.path.expanduser("~/Library/Application Support/McBlink/blink_creds.json"))

def _out(obj):
    """Print JSON line to stdout and flush immediately (for interactive I/O)."""
    print(json.dumps(obj, default=str))
    sys.stdout.flush()

async def connect():
    session = ClientSession()
    blink = Blink(session=session)
    creds = json.load(open(CREDS))
    blink.auth = Auth(creds, no_prompt=True, session=session)
    start_ok = False
    try:
        await blink.start()
        start_ok = True
    except Exception as e:
        import sys
        print(json.dumps({"warning": f"blink.start partial: {e}"}), file=sys.stderr)
    if start_ok:
        try:
            await blink.refresh()
        except Exception:
            pass
        # Only persist if we actually have a valid token — never overwrite
        # good creds with None tokens from a failed start().
        if blink.auth.token:
            try:
                await blink.save(CREDS)
            except Exception:
                pass
    return session, blink

async def cmd_cameras():
    session, blink = await connect()
    out = []
    for name, cam in blink.cameras.items():
        a = cam.attributes or {}
        out.append({"name": name, "id": a.get("camera_id") or a.get("id"),
                    "network_id": a.get("network_id"), "type": a.get("type"),
                    "battery": a.get("battery"), "armed": a.get("motion_enabled"),
                    "motion_detected": a.get("motion_detected")})
    print(json.dumps({"cameras": out}, default=str))
    await session.close()

async def cmd_snapshot(camera, out, fresh):
    session, blink = await connect()
    cam = blink.cameras.get(camera)
    if cam is None:
        print(json.dumps({"error": f"camera not found: {camera}",
                          "available": list(blink.cameras.keys())}))
        await session.close(); return
    try:
        if fresh:
            # snap_picture only QUEUES the capture. The camera wakes, takes a
            # photo, uploads to Blink's cloud — that round trip is ~5-8s. If we
            # download immediately we get the previous thumbnail. Wait + refresh
            # so image_to_file actually pulls the new image.
            await cam.snap_picture()
            await asyncio.sleep(7)
            await blink.refresh()
        await cam.image_to_file(out)
        size = os.path.getsize(out) if os.path.exists(out) else 0
        print(json.dumps({"camera": camera, "path": out, "bytes": size, "fresh": fresh}))
    except Exception as e:
        print(json.dumps({"error": f"{type(e).__name__}: {e}"}))
    await session.close()

async def cmd_auth(email=None, password=None, use_stdin=False):
    """Interactive Blink login. Keeps process alive for 2FA PIN on stdin.

    When --stdin is used, reads email\\npassword\\n from stdin first.
    If 2FA required, prints {"status":"needs_pin"} and reads PIN from stdin.
    Completes 2FA in the SAME process (session cookies + PKCE state preserved).
    """
    if use_stdin:
        email = sys.stdin.readline().strip()
        password = sys.stdin.readline().strip()
    if not email or not password:
        _out({"status": "error", "message": "email and password required"})
        return
    session = ClientSession()
    blink = Blink(session=session)
    blink.auth = Auth({"username": email, "password": password}, no_prompt=True, session=session)
    try:
        await blink.start()
        os.makedirs(os.path.dirname(CREDS), exist_ok=True)
        await blink.save(CREDS)
        _out({"status": "ok", "cameras": len(blink.cameras)})
    except BlinkTwoFARequiredError:
        _out({"status": "needs_pin"})
        pin = sys.stdin.readline().strip()
        if not pin:
            _out({"status": "error", "message": "no pin provided"})
            await session.close()
            return
        try:
            ok = await blink.auth.complete_2fa_login(pin)
            if not ok:
                _out({"status": "error", "message": "2FA verification failed"})
                await session.close()
                return
            # Tokens set. Re-run start() to finish Blink setup (login IDs,
            # URLs, homescreen). startup() uses token refresh with our new tokens.
            await blink.start()
            os.makedirs(os.path.dirname(CREDS), exist_ok=True)
            await blink.save(CREDS)
            saved = json.load(open(CREDS))
            has_token = saved.get("token") is not None
            _out({"status": "ok", "token_saved": has_token,
                  "cameras": len(blink.cameras)})
        except Exception as e:
            _out({"status": "error", "message": str(e)})
    except Exception as e:
        _out({"status": "error", "message": str(e)})
    await session.close()

async def cmd_auth_pin(pin):
    """Legacy PIN command — no longer works with OAuth2 PKCE (session state lost).
    Kept for backward compat; tells the caller to use the interactive auth flow."""
    print(json.dumps({"status": "error",
                      "message": "auth-pin is deprecated. Use 'auth' which handles PIN interactively via stdin."}))

def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd")
    sub.add_parser("cameras")
    s = sub.add_parser("snapshot")
    s.add_argument("camera"); s.add_argument("out")
    s.add_argument("--fresh", action="store_true", help="request a new thumbnail (wakes cam, uses battery)")
    a = sub.add_parser("auth")
    a.add_argument("--email", default=None)
    a.add_argument("--password", default=None)
    a.add_argument("--stdin", action="store_true",
                   help="read email\\npassword\\n (and later PIN) from stdin")
    ap = sub.add_parser("auth-pin")
    ap.add_argument("--pin", required=True)
    args = p.parse_args()
    if args.cmd == "cameras": asyncio.run(cmd_cameras())
    elif args.cmd == "snapshot": asyncio.run(cmd_snapshot(args.camera, args.out, args.fresh))
    elif args.cmd == "auth": asyncio.run(cmd_auth(args.email, args.password, args.stdin))
    elif args.cmd == "auth-pin": asyncio.run(cmd_auth_pin(args.pin))
    else: p.print_help()

main()
