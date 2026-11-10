# Agent Guide

## Mission

Maintain a small, auditable macOS microphone-monitor that favors predictable real-time behavior over framework convenience.

The application must remain understandable from its source and must not add hidden recording, persistence, networking, resampling, or voice processing.

## Repository Map

- `HeadphoneMonitor.m`: application UI and CoreAudio HAL engine
- `Info.plist`: bundle metadata and microphone usage text
- `HeadphoneMonitor.entitlements`: sandbox permissions
- `build.sh`: local build and ad-hoc signing
- `scripts/verify.sh`: static bundle and entitlement checks
- `scripts/install.sh`: clean installation into `/Applications`
- `docs/architecture.md`: data flow and real-time constraints

## Commands

```sh
make build       # Build and sign dist/Headphone Monitor.app
make test        # Run deterministic metrics tests
make verify      # Build and run repository checks
make run         # Build and launch the app
make package     # Build, verify, zip, and checksum
make install     # Build and install into /Applications
```

Use a repository-local `-fmodules-cache-path` for Clang. The build script already does this so sandboxed runs do not write to the user cache.

## Real-Time Rules

Every `AudioDeviceIOProc` runs on a real-time audio thread. Code reachable from `DuplexIOProc`, `InputIOProc`, or `OutputIOProc` must not:

- Allocate or free memory
- Acquire locks or wait on another thread
- Call Objective-C or AppKit
- Log or print
- Read or write files
- Access the network
- Perform unbounded work

Use preallocated buffers, fixed-size copies, and C11 atomics only. The render path should remain free of sample-rate conversion, gain, EQ, compression, gating, and noise reduction unless a change explicitly targets those features and includes real-time and stability testing.

Performance instrumentation may use monotonic clock reads and lock-free atomic counters. It must not allocate, log, format strings, update AppKit, or perform file or network I/O in a callback. UI formatting belongs in the main-thread metrics timer.

## Processing Constraints

- The same-device path must remain a direct HAL callback
- The separate-device path may use only the existing lock-free float bridge
- Do not add `AUVoiceProcessingIO`, `AVAudioEngine`, PortAudio, or Python to the primary path
- Reject sample-rate mismatches; do not silently resample
- Keep the app sandboxed with microphone input as the only privileged entitlement

## Verification

At minimum, run `make verify` after any source or build change.

Changes to the audio path also require manual testing for:

- Same-device input and output
- Separate input and output devices
- 32-frame and device-default buffer settings
- Microphone permission denial
- Clean and warning performance states
- Deadline, cadence, bridge, and overload counters across a long session
- Start, stop, restart, device switching, and application exit

Report hardware and macOS version with audio behavior changes.

## Change Discipline

- Keep changes focused on the monitor and its supporting developer workflow
- Preserve the no-network and no-file-access security model
- Do not commit `.build.*`, `dist`, archives, or local signing material
- Avoid unrelated formatting churn in `HeadphoneMonitor.m`
- Add architecture notes when changing callback ownership, buffering, or device negotiation
