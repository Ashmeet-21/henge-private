#!/usr/bin/env python3
"""Henge remote desktop client: shows the Mac that Henge streams from the phone and sends it mouse and keyboard.

    pip install av pygame-ce
    iproxy 15901:5901 &                 # over USB (libimobiledevice)
    python3 tools/henge-remote.py [--speed 2] [--alt-cmd]       # USB, through iproxy; --speed scales the pointer,
                                                                # --alt-cmd makes Alt Command (if the desktop keeps Super)
    python3 tools/henge-remote.py 192.168.1.20:5901 --code 123456   # Wi-Fi: allow it in Henge, use the code it shows

The Mac's sound comes on the video port + 2 (iproxy 15903:5903 over USB); --no-audio leaves it on the phone.

Click the window to capture the mouse; Left Ctrl + Left Alt lets it go. The protocol is in ios/Henge/RemoteDesktop.swift:
H.264 Annex-B one way, 6-byte input messages [type][a][x int16 LE][y int16 LE] the other.
"""
import os, socket, struct, sys, threading
# While the mouse is captured, the keyboard is too: on Wayland that asks the compositor (KWin, GNOME) to stop its own
# shortcuts, so Super+Q reaches the Mac as Command-Q instead of the desktop.
os.environ.setdefault("SDL_GRAB_KEYBOARD", "1")
os.environ.setdefault("SDL_VIDEODRIVER", "wayland,x11")
import av
import pygame

args = sys.argv[1:]
code, speed, alt_cmd, audio = None, 2.0, False, True
if "--no-audio" in args:
    audio = False
    args.remove("--no-audio")
if "--alt-cmd" in args:  # Alt is Command and Super is Option, as a Mac keyboard has them laid out
    alt_cmd = True
    args.remove("--alt-cmd")
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
_name = socket.gethostname().split(".")[0].encode()[:63]  # what the phone shows it's streaming to
sock.sendall(struct.pack("<BBhh", 5, len(_name), 0, 0) + _name)
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


class Sound:
    """The Mac's sound from the phone: packets of [length u32][rate u32][channels u16][format u16] + PCM, played through
    SDL with a short buffer. More than a quarter second behind and it skips ahead, so the sound stays with the picture."""
    FORMATS = {5: ("AUDIO_S16", 2), 17: ("AUDIO_S32", 4), 19: ("AUDIO_F32", 4)}

    def __init__(self):
        self.buf, self.lock, self.device, self.shape = bytearray(), threading.Lock(), None, None

    def fill(self, device, out):
        with self.lock:
            n = min(len(out), len(self.buf))
            out[:n] = self.buf[:n]
            del self.buf[:n]
        out[n:] = bytes(len(out) - n)  # nothing yet: silence

    def open(self, rate, channels, fmt):
        from pygame._sdl2 import audio as sdl
        if self.device:
            self.device.close()
        name, size = self.FORMATS[fmt]
        self.bytes_per_second = rate * channels * size
        from pygame._sdl2 import sdl2
        pygame.mixer.quit()  # pygame.init() opened the default output for a mixer this never uses; that also stops
        sdl2.init_subsystem(sdl2.INIT_AUDIO)  # SDL's sound, so start it again for a device of our own
        self.device = sdl.AudioDevice(None, False, rate, getattr(sdl, name), channels, 512, 0, self.fill)
        self.device.pause(0)
        self.shape = (rate, channels, fmt)

    def run(self, host, port, code):
        try:
            a = socket.create_connection((host, port), timeout=5)
        except OSError as e:
            print(f"no sound: {host}:{port}: {e} (over USB: iproxy 15903:5903)", flush=True)
            return
        a.settimeout(None)
        if code:
            a.sendall(code.encode()[:6].rjust(6, b"0"))
        f = a.makefile("rb")
        while running:
            head = f.read(12)
            if len(head) < 12:
                break
            n, rate, channels, fmt = struct.unpack("<IIHH", head)
            data = f.read(n)
            if len(data) < n or fmt not in self.FORMATS:
                continue
            if self.shape != (rate, channels, fmt):
                self.open(rate, channels, fmt)
            with self.lock:
                self.buf += data
                frame = channels * self.FORMATS[fmt][1]
                if len(self.buf) > self.bytes_per_second // 4:  # behind: keep the newest tenth of a second
                    keep = (self.bytes_per_second // 10) // frame * frame
                    del self.buf[:len(self.buf) - keep]


pygame.init()
pygame.display.set_caption(f"Henge - {host}")
screen = pygame.display.set_mode((1280, 720), pygame.RESIZABLE)
threading.Thread(target=reader, daemon=True).start()
if audio:
    threading.Thread(target=Sound().run, args=(host, int(port or 15901) + 2, code), daemon=True).start()

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
        if os.environ.get("HENGE_REMOTE_LOG"):  # debugging: every move as sent
            print(f"move {dx:+d} {dy:+d}", flush=True)
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
            if size != (w, h):  # a new stream size: start the window at it, then it is the user's to resize
                size = (w, h)
                screen = pygame.display.set_mode(size, pygame.RESIZABLE)
            picture = pygame.image.frombuffer(pixels, size, "RGB", pitch)
            screen = pygame.display.get_surface()  # resizing the window gives it a new one
            win = screen.get_size()
            if win == size:
                screen.blit(picture, (0, 0))
            else:  # fit the window, keeping the Mac's shape: black bars where the shapes differ
                k = min(win[0] / w, win[1] / h)
                fit = (max(1, round(w * k)), max(1, round(h * k)))
                screen.fill((0, 0, 0))
                screen.blit(pygame.transform.smoothscale(picture, fit), ((win[0] - fit[0]) // 2, (win[1] - fit[1]) // 2))
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
            usage = e.scancode  # SDL scancodes are USB HID keyboard usages: Super (227/231) is Command on the Mac
            if alt_cmd:
                usage = {226: 227, 227: 226, 230: 231, 231: 230}.get(usage, usage)
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
