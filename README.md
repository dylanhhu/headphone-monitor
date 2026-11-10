# Headphone Monitor

Headphone Monitor is a native macOS menu-bar application that routes microphone audio to a selected output device with as little application-side latency as possible.

The application is written in Objective-C and C. It uses CoreAudio HAL I/O callbacks directly and does not include Python, PortAudio, AVFoundation, AudioUnit graphs, or voice-processing units.

## Status

This is an early `0.1.0` prototype intended for local testing and further latency research.

## Behavior

- Direct input-to-output copy when both directions use the same CoreAudio device
- Lock-free bridge when input and output use different devices
- Device selection from the menu bar
- Selectable buffer sizes, including the device-reported minimum, defaulting to 32 frames
- Exact sample-rate matching with no hidden resampling
- Live callback, deadline, cadence, bridge, and CoreAudio overload counters
- App Sandbox with microphone input as the only privileged entitlement
- No network entitlement
- No audio recording or persistence

## Requirements

- macOS 11 or later
- Apple Command Line Tools or Xcode with the macOS SDK

The build does not require Python, Homebrew packages, or third-party dependencies.

## Build

```sh
make build
```

The application bundle is written to `dist/Headphone Monitor.app`.

## Run

```sh
make run
```

Open the microphone icon in the menu bar, select the input and output devices, and choose **Start Monitoring**. macOS requests microphone permission on first use.

## Install

```sh
make install
```

This installs the signed bundle into `/Applications`. An existing installation is moved to a temporary backup instead of being overwritten in place.

## Verify

```sh
make verify
```

Verification checks the property lists, compilation, ad-hoc signature, required microphone entitlement, and absence of network or file-access entitlements.

Run the deterministic metrics tests independently with `make test`.

## Latency Model

The `N frames` setting controls the CoreAudio device buffer request. At 48 kHz, 32 frames corresponds to 0.667 ms per buffer before operating-system and hardware overhead.

**Minimum Supported** requests the smallest legal buffer reported by each selected device. The resulting input and output sizes can differ when the devices expose different ranges; the Performance menu reports the actual negotiated sizes.

The minimum is a driver allowance, not a guarantee of glitch-free operation. If deadline, cadence, underrun, or overload counters rise, select the next larger buffer.

Latency is lowest when:

- Input and output use one physical CoreAudio device
- Input and output use the same nominal sample rate
- Output is wired rather than Bluetooth or AirPlay
- The device accepts a small buffer without dropouts

The separate-device path primes one input buffer plus one output buffer, which is the previous two-output-buffer target when the devices use equal sizes. Its application-side bridge therefore contributes up to that prefill interval in addition to input and output latency. Once prefill completes, the first output callback discards any stale frames accumulated while waiting for CoreAudio to start the output stream, keeping the bridge at its intended occupancy.

## Performance Monitoring

Open **Performance** in the menu to inspect the current session:

- Callback rates for input and output
- Average and maximum callback work time
- Deadline misses when callback work exceeds one device-buffer period
- Cadence misses when callbacks arrive later than expected
- Current and maximum bridge occupancy for separate devices
- Frames discarded from stale pre-start bridge prefill
- Output underruns, input ring overflows, and clock-drift corrections
- CoreAudio processor-overload notifications

The menu-bar icon changes to a warning symbol when any counter reports a potentially audible problem. `Reset Counters` starts a new observation window without restarting audio.

- `INFO` identifies descriptive values or a stopped stream
- `OK` means no problem is currently observed for that counter
- `WARN` means degraded behavior that may or may not be audible
- `ERROR` means samples were likely dropped, duplicated, or delivered late

Current thresholds:

- Callback work at 75% or more of the shortest buffer period is `WARN`; 100% or more is `ERROR`
- Any deadline miss, output underrun, input-ring drop, or CoreAudio overload is `ERROR`
- Any cadence miss is `WARN`; cadence misses at 0.1% or more of callbacks are `ERROR`
- A bridged-device fill below one output buffer is `WARN`; an empty bridge is `ERROR`
- Any drift correction is `WARN` because it implies missing or repeated samples, even when inaudible
- Callback rates below 80% of the expected device rate are `WARN`; below 50% are `ERROR`

These counters detect symptoms. A clean counter set does not prove that a driver or hardware component did not conceal a dropout.

## Processing Boundary

The application does not instantiate `AUVoiceProcessingIO`, enable `AVAudioEngine` voice processing, apply gain, equalize, gate, denoise, or resample. It receives the HAL device stream and copies float32 PCM frames to the output.

macOS can still apply processing in CoreAudio, a device driver, Bluetooth, or hardware before the application receives audio. There is no public API for a sandboxed application to bypass those layers. Apple documents the explicit voice-processing bypass as a property of `AUVoiceProcessingIO`; this project intentionally does not use that unit.

See [Architecture](docs/architecture.md) for implementation details.

## Privacy And Security

- The process has microphone-input permission
- The process has no network client or server entitlement
- The process has no user-file entitlement
- Audio exists only in real-time buffers and is never recorded
- The app does not persist selected devices or buffer sizes between launches

## Project Layout

```text
HeadphoneMonitor.m             Native application and CoreAudio engine
Info.plist                     Application metadata
HeadphoneMonitor.entitlements  App Sandbox capabilities
build.sh                       Reproducible local bundle build
scripts/                       Verification, installation, and packaging
tests/                         Callback and bridge metric tests
docs/                          Architecture and development notes
```

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) before changing the real-time audio path. Agent-driven changes must also follow [AGENTS.md](AGENTS.md).

## Next Exploration

The next technical area is optional ultra-low-latency noise rejection while preserving the real-time callback constraints and the current processing boundary.
