#!/usr/bin/env python3
"""Henge remote desktop client: shows the Mac that Henge streams from the phone and sends it mouse and keyboard.

    pip install av pygame-ce
    iproxy 15901:5901 &                 # over USB (libimobiledevice)
    python3 tools/henge-remote.py [--speed 2]                   # USB, through iproxy; --speed scales the pointer
    python3 tools/henge-remote.py 192.168.1.20:5901 --code 123456   # Wi-Fi: allow it in Henge, use the code it shows

Click the window to capture the mouse; Left Ctrl + Left Alt lets it go. The protocol is in ios/Henge/RemoteDesktop.swift:
H.264 Annex-B one way, 6-byte input messages [type][a][x int16 LE][y int16 LE] the other.
"""
import os, socket, struct, sys, threading
os.environ.setdefault("SDL_RENDER_SCALE_QUALITY", "linear")  # a resized window is filtered, not pixel-doubled unevenly
import av
import pygame

args = sys.argv[1:]
code, speed = None, 2.0
if "--speed" in args:  # pointer speed: Henge's own trackpad moves the Mac's pointer 2-3x what a finger moves
    i = args.index("--speed")
    speed = float(args[i + 1])
    del args[i:i + 2]
if "--code" in args:
    i = args.index("--code")
    code = args[i + 1]
    del args[i:i + 2]
host, _, port = (args[0] if args else "127.0.0.1:15901").partition(":")
sock = socket.create_connection((host, int(port or 15901)))
sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
if code:
    sock.sendall(code.encode()[:6].rjust(6, b"0"))
send_lock = threading.Lock()


def send(kind, a=0, x=0, y=0):
    x, y = max(-32768, min(32767, int(x))), max(-32768, min(32767, int(y)))
    global running
    try:
        with send_lock:
            sock.sendall(struct.pack("<BBhh", kind, a, x, y))
    except OSError:
        running = False  # the phone hung up


latest, latest_lock, running = None, threading.Lock(), True
NEW_FRAME = pygame.event.custom_type()


def reader():
    """Decode as bytes arrive, keeping only the newest picture: a slow window drops frames instead of falling behind."""
    global latest, running
    codec = av.CodecContext.create("h264", "r")
    codec.flags |= av.codec.context.Flags.low_delay
    codec.thread_type = "SLICE"
    while running:
        data = sock.recv(1 << 16)
        if not data:
            break
        for packet in codec.parse(data):
            try:
                frames = codec.decode(packet)
            except av.error.InvalidDataError:
                continue
            for f in frames:
                plane = f.reformat(format="rgb24").planes[0]
                with latest_lock:
                    latest = (bytes(plane), f.width, f.height, plane.line_size)
                pygame.event.post(pygame.event.Event(NEW_FRAME))
    running = False
    pygame.event.post(pygame.event.Event(pygame.QUIT))


pygame.init()
pygame.display.set_caption(f"Henge - {host}")
screen = pygame.display.set_mode((1280, 720), pygame.RESIZABLE)
threading.Thread(target=reader, daemon=True).start()

captured = False
size = None
BUTTONS = {1: 0, 2: 2, 3: 1}  # pygame left, middle, right -> Henge 0 left, 1 right, 2 middle


def capture(on):
    global captured
    captured = on
    pygame.event.set_grab(on)
    pygame.mouse.set_visible(not on)
    pygame.mouse.set_relative_mode(on)
    pygame.display.set_caption(f"Henge - {host}" + (" (Left Ctrl + Left Alt releases the mouse)" if on else " (click to control)"))


capture(False)
held = set()
move = [0.0, 0.0]  # pointer motion not yet sent: a batch of events goes as one move


def flush_move():
    dx, dy = int(move[0]), int(move[1])
    if dx or dy:
        send(1, 0, dx, dy)
        move[0] -= dx
        move[1] -= dy


while running:
    for e in [pygame.event.wait()] + pygame.event.get():
        if e.type == pygame.QUIT:
            running = False
        elif e.type == NEW_FRAME:
            with latest_lock:
                frame, latest = latest, None
            if frame is None:
                continue
            pixels, w, h, pitch = frame
            if size != (w, h):
                size = (w, h)
                screen = pygame.display.set_mode(size, pygame.RESIZABLE | pygame.SCALED)
            screen.blit(pygame.image.frombuffer(pixels, size, "RGB", pitch), (0, 0))
            pygame.display.flip()
        elif e.type == pygame.MOUSEBUTTONDOWN and not captured:
            if e.button in BUTTONS:
                capture(True)
        elif e.type == pygame.MOUSEMOTION and captured:
            move[0] += e.rel[0] * speed
            move[1] += e.rel[1] * speed
        elif e.type in (pygame.MOUSEBUTTONDOWN, pygame.MOUSEBUTTONUP) and captured and e.button in BUTTONS:
            flush_move()  # a click lands where the pointer is by then
            send(2, BUTTONS[e.button], 1 if e.type == pygame.MOUSEBUTTONDOWN else 0)
        elif e.type == pygame.MOUSEWHEEL and captured:
            flush_move()
            send(3, 0, e.x, e.y)
        elif e.type in (pygame.KEYDOWN, pygame.KEYUP):
            mods = pygame.key.get_mods()
            if e.type == pygame.KEYDOWN and captured and mods & pygame.KMOD_LCTRL and mods & pygame.KMOD_LALT:
                for usage in held:
                    send(4, usage, 0)
                held.clear()
                capture(False)
                continue
            usage = e.scancode  # SDL scancodes are USB HID keyboard usages
            if not captured or not 0 < usage < 256:
                continue
            down = e.type == pygame.KEYDOWN
            (held.add if down else held.discard)(usage)
            send(4, usage, 1 if down else 0)
        elif e.type == pygame.WINDOWFOCUSLOST and captured:
            for usage in held:
                send(4, usage, 0)
            held.clear()
            capture(False)
    if captured:
        flush_move()

sock.close()
pygame.quit()
