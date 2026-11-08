# Native touch

Native touch sends direct contact input to a macOS 27.2 or later guest.
Trackpad mode is the default and the fallback when native touch is unavailable.

## Setup

1. In the guest, focus Terminal. Open Henge's Details panel and choose
   **Touch input → Type the Helper Update Command**, then press Return in Terminal.
2. Allow Accessibility for `henge-touch-agent` in the guest's System Settings.
   The helper also requires authorization to create its virtual HID device.
3. Enable **Native touch (experimental)** in Details, then close the panel.

The setting is saved. Details shows connection and permission errors.
Transport timeouts retry automatically after the guest helper connects.

## Behaviour

The virtual touchscreen binds to the guest's main display and supports up to
five contacts. Coordinates follow the displayed image, including zoom.
Contact transitions are queued, and movement with the same contacts is coalesced.
Idle requests wait up to 250 ms; new input wakes them immediately.

Opening a Henge panel, backgrounding the app, or changing image geometry releases
the contacts. Missing heartbeats also release input and restore trackpad mode.
An external display uses the phone's trackpad controls.
When controls are hidden, a three-finger tap reveals them.

## Development

Build with Xcode 27.3 or newer. The iOS build bundles the guest touch helper.
Run the focused checks from the repository root:

```sh
tools/check_native_touch.sh
```

These cover the transport, contact transitions, timeouts, reconnection, and Swift
compilation. Hardware testing on an iPhone Duo covered direct touch on macOS 27.2
and direct touch with the newer touch UI on macOS 27.3.
