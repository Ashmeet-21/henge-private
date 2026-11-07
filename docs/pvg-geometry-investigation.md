# PVG geometry investigation and candidate build

Status: a decoder bounds defect is corrected and synthetic regressions are added.
**The Roblox geometry corruption has not been reproduced or confirmed fixed.**
No guest capture or screen recording was available during the initial source audit.
A clean build proves packaging, not rendering correctness on the iPad Air M4.

## Architecture traced

1. `pvg_lite.c:do_channel` reads guest FIFO channel rings, drains channel dependency
   stamps, copies each command, and calls `hv_pvg_metal_submit`.
2. `hv_pvg_metal_submit` queues commands on one serial worker. Exec operations
   0x43/0x45 resolve the task resource list and upload guest-written heap/texture
   resources before decoding copied command-buffer segments.
3. Segments identify render/compute/blit/info encoders; each contains packed
   `{tag, total size}` records. A render tag 26 creates the Metal render pass.
4. `HvReplay render:tag:rec:task:` forwards decoded bindings and draw parameters
   to Metal. Ordinary and dynamic-stride vertex bindings use their respective
   native APIs. Indirect draws keep their arguments GPU-owned.
5. Shader libraries and Metal's serialized pipeline-descriptor SPI reconstruct
   pipeline state, including vertex layouts and function references. Henge does
   not manually invent Roblox vertex layouts. Function selection currently uses
   the library's first function; multi-function libraries need evidence before
   changing that behavior.
6. Metal command buffers commit to one queue. Completion handlers return guest
   stamps after completion. Frame presentation and cursor overlay use the
   separate presenter path. `pvg_mac.m` delegates to Apple's macOS-only
   ParavirtualizedGraphics framework; it is not another packed-command decoder.

## Confirmed defect and correction

The outer decoder checked record framing, but fixed-field handlers could still
read beyond the record's *payload*. In the audited upstream version:

- `render:` at `pvg_metal.m:1018–1032` only checked `count <= 31` before reading
  vertex/fragment/tile buffer arrays. A record saying two bindings but containing
  one could read the following record as its second reference/offset.
- Compute buffer binding tag 203 at upstream lines 1393–1404 had the same defect.
- Both ordinary and dynamic-stride bindings lacked combined `index + count`
  slot bounds. A slot-30/count-2 range exceeds Metal's slots 0–30.
- Draw handlers did not check their minimum payload sizes. Direct indexed and
  indirect draws did not validate their buffer class, alignment or storage span.
- Serialized pipeline descriptors did not check the embedded data length before
  passing it to Metal's deserializer.

`pvg_decode.h` provides subtraction/division-based checks that cannot overflow.
Replay rejects these provably invalid payloads, ranges and index/indirect spans
before lookup/encoding. Normal valid wire fields and API overloads are unchanged.
Single buffer-offset records and serialized sampler/depth lengths are also guarded.
Optional render-pass diagnostic reads are bounded. This is intentionally not a
claim that every texture/sampler/state/compute/blit decoder is now hardened.

A malformed record can bind incorrect data or cause invalid GPU accesses, which
can produce stretched/duplicated geometry. **There is no evidence yet that Roblox
submits one of these failing records.** Treat the correction as a bounded decoder
fix and candidate explanation until device logs demonstrate that relationship.

We did not change base-vertex signedness: compact tag 11 is unsigned and tag 29
is signed in the existing protocol, while wide variants preserve their current
64-bit representation. No shader rewrite, topology guess, feature disabling,
application-specific workaround or global GPU wait was introduced.

## Other hypotheses requiring workload evidence

- A failed placement-heap buffer allocation falls back to independent private
  storage. Existing heap uploads target the parent heap, so the fallback does
  not preserve alias contents. New diagnostics flag this path; no speculative
  aliasing rewrite is included.
- Remapped guest pages can produce a new Metal buffer/generation. Raw GPU
  addresses previously exported into argument buffers may need renewal. New
  diagnostics flag remaps, but a capture must establish stale-address use.
- Guest-write and GPU-write invalidation have different parent propagation.
  A trace must establish whether Roblox lists child resources without parents.
- Unsupported render/compute/blit tags may matter for this workload. The new
  summaries and warnings make them visible without changing unknown formats.
- IOSurface sampling can miss some multi-plane updates, but that separate texture
  path is not a supported explanation for mesh geometry and is outside this patch.

## Opt-in diagnostics

In **Settings > Graphics**, enable **Collect GPU diagnostics**, then fully close
and reopen Henge before starting a guest. The preference is off by default.
It applies `HV_PVG_DIAGNOSTICS=1` before boot/install creates the renderer. On a Mac,
set that environment variable before launching HengeVM.

`henge.log` records command tags and decoded direct/indexed counts, offsets,
instances, base vertex/base instance, vertex buffer refs/offsets/dynamic strides,
pipeline vertex attribute format/offset/stride/step metadata, resource generations,
missing/wrong references, invalid spans, unsupported operations and remaps.
Indirect argument-buffer references and offsets are logged; GPU-produced argument
values are deliberately not CPU-read before execution.

For a session, detail output is capped at 384 lines, warnings have an independent
128-line budget, and at most 32 summaries are emitted at least ten seconds apart.
Counters continue after detailed output fills. Early startup may consume detail
capacity; later warnings and cumulative tag summaries still help identify a fault.
There is no guest memory, buffer-content, shader-code or credential dump. Turn
this setting off for ordinary use and performance comparisons.

## Automated tests and their limits

`ios/scripts/check_gpu.sh` runs:

- Portable C checks for truncated packed arrays, slot bounds, integer overflow,
  buffer spans, and compact/wide draw payload boundaries.
- Recording-encoder tests that call the **actual replay methods**, checking
  binding refs/offsets/dynamic strides, indexed/base-vertex/base-instance forwarding,
  indirect argument offsets, and rejection of malformed payloads before lookup.
- A pre-change regression proof when the pinned upstream source is available:
  the same fixture must fail on the old replay at its specific truncated-draw
  assertion, while the patched replay passes.
- Offscreen native Metal image tests, when a Metal device is available: indexed
  and indirect instanced triangles, padded vertex/index offsets, base vertex,
  depth occlusion and dynamic shared-buffer updates. No device produces an
  explicit SKIP; it must not be reported as a rendering pass.

The fixture uses a small synthetic shader/resource table rather than guest
shader serialization or a complete macOS VM. It does not establish Roblox,
Finder, Safari, cursor, JIT, restore or physical iPad rendering correctness.
Those remain device acceptance tests. The IPA manifest retains test logs and
any explicit native-test skips. The full iOS app/engine build and strict bundle
validation separately check resources, JIT entitlements, IDs, StikJIT/helper,
firmware exclusion and the preserved avp-ctrr and mouse-fix ancestry.

## iPad Air M4 acceptance checklist

1. Re-sign `Henge-M4-GPUFix.ipa` and nested bundles with your development
   certificate; install with KravaSign. Confirm built-in StikJIT enables normally.
2. With diagnostics off, boot the same guest and check desktop transparency,
   Finder, Safari text/images/video, cursor appearance/movement and right/middle
   physical mouse compatibility. Check scrolling and touch controls.
3. Open the same Roblox experience, camera position and graphics settings used
   in the original recording. Capture before/after scenes with repeated meshes,
   stretched surfaces and normally rendered objects, then try another experience.
   Check sustained frame rate only after visual correctness.
4. For evidence, enable diagnostics, fully reopen Henge and reproduce promptly.
   Share **Settings > Log > Share henge.log**, the recording, guest macOS build,
   Roblox version and graphics settings. Relevant prefixes are `pvgdiag:` and
   `hengevm: pvg-metal:`. A warning identifies a candidate operation; its absence
   does not prove no rendering defect exists.
5. Watch for invalid payload/range/resource warnings, placement fallback,
   unsupported tag summaries, remaps or command-buffer errors. These distinguish
   the current candidate from shader, aliasing and synchronization hypotheses.
6. Confirm JIT, cursor and normal desktop rendering across background/foreground
   and reconnecting a display if used. Test boot/restore compatibility using a
   disposable guest or backup; do not risk your only guest disk.

Report whether corruption is unchanged, reduced, or absent, and attach the logs.
Only physical-device evidence can close the Roblox rendering issue.
