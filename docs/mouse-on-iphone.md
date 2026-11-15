# A mouse on iPhone

On iPad, a Bluetooth or USB mouse or trackpad reaches the Mac through GameController (`GCMouse`), with the
iPad's own pointer locked away while Henge fills the screen. On iPhone that path is mostly closed, and this
page records what is reachable and what Henge does with it.

## What iOS lets an app read on iPhone

- **GameController (`GCMouse`):** iOS announces a paired mouse to the app, button count included, but passes on
  none of its input unless AssistiveTouch is on. With AssistiveTouch off, the handlers never run and polled
  state never changes (checked on an iPhone with an MX Master 4: no moves, buttons `000`, scroll `0` for 20 s
  while the mouse was moved and clicked). Pointer lock doesn't exist on iPhone.
- **Standard Bluetooth mouse channel:** iOS hides HID over GATT (service `0x1812`) from apps.
- **Bluetooth Classic and USB mice:** an iPhone app has no access to either. Apple's Magic Mouse (every model) is
  Bluetooth Classic only.
- **A maker's own Bluetooth LE service:** reachable. Logitech mice carry HID++ beside standard HID.

So without AssistiveTouch, the only way in is a mouse's vendor channel.

## Logitech mice over HID++

`ios/Henge/MouseBluetooth.swift`. When a Mac starts on an iPhone, `VendorMice` finds the mice iOS already holds
connected (by device information, battery and Logitech's service) and logs every service each one exposes.
A mouse with Logitech's service `00010000-0000-1000-8000-011F2000046D` gets an `HIDPPMouse` on its
characteristic `00010001-0000-1000-8000-011F2000046D` (write and notify).

**Framing.** Over Bluetooth LE a HID++ 2.0 message is 18 bytes: feature index, then function and software id in
one byte, then 16 bytes of parameters. There is no report id and no device index; the characteristic refuses a
19- or 20-byte write as an invalid length. A reply echoes the feature index and the function with Henge's
software id (`0x0A`), an event carries software id 0, and an error starts with `0xFF`.

**Set up**, from the root feature (index 0):

1. `0x1D4B` wireless device status. Its event "reconfiguration needed" (sent when the mouse reconnects or
   wakes) runs the set up again.
2. `0x1B04` reprogrammable controls v4. Every control is listed (`getCidInfo`). Left (`0x50`) and right (`0x51`)
   can't be diverted, so they're asked for analytics key events. Middle (`0x52`) is diverted. Raw motion is
   forced onto one control that can carry it (`0xD7` on an MX Master 4). Other controls are left alone, so,
   for example, the MX Master's wheel-mode button still switches its wheel between ratchet and free spin.
3. `0x2121` high-resolution wheel, set to report to HID++ in low resolution: one count per detent.
4. `0x2150` thumbwheel, diverted. Its rotation is turned into horizontal wheel detents (diverted resolution / 24
   per detent).

**Events** go to `HardwareMouse` as raw counts, unscaled, so macOS's own mouse settings decide how the mouse
feels: raw motion (signed 16-bit dx, dy, Y down), buttons (analytics for left and right, diverted buttons for
middle), the wheel and the thumbwheel.

**Handing it back.** None of the diversion is persistent. Henge undoes it when the Mac stops and whenever Henge
leaves the screen, and turning the mouse off and on also undoes it.

Checked on an iPhone with an MX Master 4: movement, left, right and middle clicks, the wheel and the thumbwheel
all reach macOS with AssistiveTouch off.

## Other mice

Any mouse or trackpad works through GameController once AssistiveTouch is on. If a mouse connects with
AssistiveTouch off and no vendor channel opens within 8 s, Henge says to turn AssistiveTouch on. AssistiveTouch
draws its own pointer on the phone. UIKit leaves a pointer interaction's drivers detached on iPhone, so Henge
attaches them after UIKit's own update, as on iPad (`PhonePointer`), so that the trackpad's request to hide the
pointer over the Mac is made at all. Whether iOS then hides AssistiveTouch's pointer is still untested. While a Logitech mouse passes
through HID++, Henge ignores GameController's copy of it, so no click arrives twice. Another brand's mouse
can get the same treatment if it carries a vendor channel; its services show up in the log as
`[mouse-bt] ... services: [...]`.
