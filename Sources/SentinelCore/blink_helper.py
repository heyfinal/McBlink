#!/usr/bin/env python3
"""McBlink Blink bridge — JSON CLI over blinkpy for SentinelCore.
Persistent auth via saved creds (no 2FA after first login)."""
import asyncio, os, json, argparse
from aiohttp import ClientSession
from blinkpy.blinkpy import Blink
from blinkpy.auth import Auth

CREDS = os.environ.get("BLINK_CREDS",
    os.path.expanduser("~/Library/Application Support/McBlink/blink_creds.json"))
PARTIAL_AUTH = "/tmp/mcblink_blink_auth.json"

async def connect():
    session = ClientSession()
    blink = Blink(session=session)
    blink.auth = Auth(json.load(open(CREDS)), no_prompt=True, session=session)
    await blink.start()
    await blink.refresh()
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

async def cmd_auth(email, password):
    """Start Blink login. Returns {"status":"ok"} or {"status":"needs_pin"} for MFA."""
    session = ClientSession()
    blink = Blink(session=session)
    blink.auth = Auth({"username": email, "password": password}, no_prompt=True, session=session)
    try:
        await blink.start()
    except Exception:
        pass
    if blink.auth.is_errored:
        with open(PARTIAL_AUTH, "w") as f:
            json.dump(blink.auth.login_response, f)
        print(json.dumps({"status": "needs_pin"}))
    else:
        os.makedirs(os.path.dirname(CREDS), exist_ok=True)
        blink.save(CREDS)
        print(json.dumps({"status": "ok"}))
    await session.close()

async def cmd_auth_pin(pin):
    """Complete Blink MFA login with the emailed/texted verification code."""
    if not os.path.exists(PARTIAL_AUTH):
        print(json.dumps({"status": "error",
                          "message": "No pending auth session — run auth --email … --password … first"}))
        return
    with open(PARTIAL_AUTH) as f:
        login_response = json.load(f)
    session = ClientSession()
    blink = Blink(session=session)
    blink.auth = Auth(login_response, no_prompt=True, session=session)
    try:
        await blink.auth.send_auth_key(blink, pin)
        os.makedirs(os.path.dirname(CREDS), exist_ok=True)
        blink.save(CREDS)
        try:
            os.unlink(PARTIAL_AUTH)
        except OSError:
            pass
        print(json.dumps({"status": "ok"}))
    except Exception as e:
        print(json.dumps({"status": "error", "message": str(e)}))
    await session.close()

def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd")
    sub.add_parser("cameras")
    s = sub.add_parser("snapshot")
    s.add_argument("camera"); s.add_argument("out")
    s.add_argument("--fresh", action="store_true", help="request a new thumbnail (wakes cam, uses battery)")
    a = sub.add_parser("auth")
    a.add_argument("--email", required=True)
    a.add_argument("--password", required=True)
    ap = sub.add_parser("auth-pin")
    ap.add_argument("--pin", required=True)
    args = p.parse_args()
    if args.cmd == "cameras": asyncio.run(cmd_cameras())
    elif args.cmd == "snapshot": asyncio.run(cmd_snapshot(args.camera, args.out, args.fresh))
    elif args.cmd == "auth": asyncio.run(cmd_auth(args.email, args.password))
    elif args.cmd == "auth-pin": asyncio.run(cmd_auth_pin(args.pin))
    else: p.print_help()

main()
