# A16 performance and compatibility review context

Updated 2026-11-07 on branch `port-upstream-perf` (starting HEAD `3352534`).

## User goal

Improve Henge for A16 iPhones: strong sustained performance, reliable operation, and the broadest practical macOS app compatibility. Do not promise every Mac app will work; explain architectural limits clearly.

## Current A16 profile in this branch

- Low-memory devices default to 2 guest CPUs and 3 GB guest RAM (`ios/Henge/Hardware.swift`). Keep these defaults for A16-class 6 GB phones unless device measurements support a change.
- A 512 MB JIT code region is the low-memory default. A 1 GB region reduces code-cache flushes but consumes another 512 MB of real memory and previously caused memory pressure on 6 GB devices.
- 1280x720 reduces display work and surface memory; 1600x900 and 1920x1080 remain quality options.
- The thermal governor, 30 Hz display option, faster disk flush setting, and experimental superblocks already exist.
- Existing engine work includes table-major TLB layout and a memory slow-path optimization with benchmark notes in commit history. Keep superblocks experimental until workload measurements support changing the default.

## Compatibility boundaries

- Henge executes an Apple virtual Mac ARM64 guest and implements its devices and Metal graphics replay. Correct ARM64/system-register behavior and GPU command coverage are separate compatibility requirements.
- Upstream has publicly stated Rosetta 2 is unsupported because the emulated CPU does not expose a feature Rosetta requires; Windows would need a different virtual machine/device model. Treat these as major separate projects, not tuning options.
- Upstream's first release reports testing on iPhone 17 Pro and notes that other apps may render incorrectly. A16 and iPad compatibility require real-device regression coverage.

## Changes made in this pass

- WebDAV path validation now rejects symlinks in existing path components to prevent stable symlinks from redirecting shared-folder operations outside the selected folder.
- WebDAV GET validates unsatisfiable byte ranges and handles allocation failure before sending response headers; PUT handles allocation failure and cleans up its temporary file.
- Sparse pack/unpack now protects against source/destination aliasing, propagates unexpected sparse-seek failures, handles interrupted/partial I/O, bounds-checks records without integer wraparound, and rejects logical sizes outside signed 64-bit file offsets.

## Next engineering steps

1. Build and run the existing test suite on macOS; add focused coverage for WebDAV range/path handling and sparse-image malformed input, same-file paths, and partial I/O.
2. Benchmark 2/3/4 guest CPUs, 3/4 GB RAM, 512 MB/1 GB JIT region, and 720p/900p on a physical A16 under both short and sustained workloads. Record thermal and jetsam outcomes.
3. Add app compatibility cases that exercise ARM64 instructions, system calls/registers, and Metal rendering. Log unsupported GPU commands instead of silently drawing incorrect output.
4. Consider descriptor-relative (`openat`/`renameat`) WebDAV operations if the shared-folder threat model requires protection against concurrent symlink swaps, not just existing symlink components.

No build or tests were run in the context-saving pass.
