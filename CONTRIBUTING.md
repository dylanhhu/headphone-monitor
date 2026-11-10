# Contributing

## Prerequisites

- macOS 11 or later
- Current Apple Command Line Tools or Xcode

There are no package-manager dependencies.

## Development Loop

```sh
make verify
make run
```

`make verify` rebuilds the application, runs deterministic metrics tests, and validates metadata, signature, and sandbox entitlements.

## Manual Audio Test Matrix

Run the relevant cases when changing device negotiation, buffer sizing, callbacks, or the menu interface:

| Case | Expected result |
| --- | --- |
| Same input and output device | Direct callback path, no extra application bridge |
| Different input and output devices | Audio continues through the lock-free bridge |
| Mismatched sample rates | Start is refused with an actionable message |
| Minimum supported buffer | Uses each device's smallest legal buffer and reports the negotiated sizes |
| 32-frame buffer | Starts if supported; otherwise clamps to the driver range |
| Device-default buffer | Uses the current device buffer size |
| Microphone permission denied | Start fails without a crash |
| Stop and restart | Audio stops cleanly and restarts without duplicate callbacks |
| Device switched while running | Old callbacks stop before the new stream starts |
| Unplug selected device | The app does not crash; select a valid replacement |
| Performance menu | Rates and counters update once per second |
| Warning state | Relevant counters increment and change the status icon |
| Reset counters | Counters clear without restarting the stream |

Record the macOS version, Mac model, input device, output device, and sample rate with audio-path pull requests.

## Real-Time Code

The CoreAudio callbacks are real-time critical. Do not add allocation, logging, file access, networking, locks, Objective-C calls, or unbounded loops to the I/O path.

Keep the direct same-device path free of application buffering. Any additional processing must have a measured benefit and a documented latency cost.

Performance instrumentation must remain bounded and lock-free. Do not move menu formatting or other Objective-C work into the callback. Use the existing one-second main-thread timer for presentation.

## Security And Privacy

The app must remain sandboxed with:

- `com.apple.security.app-sandbox`
- `com.apple.security.device.audio-input`

Do not add network, arbitrary file, automation, or accessibility entitlements without an explicit design discussion. Do not add recording or telemetry.

Report a security issue privately through GitHub security advisories when available rather than opening a public issue.

## Code Style

- Compile with the flags in `build.sh` and keep the build warning-free
- Use C11 atomics for cross-thread callback state
- Keep allocation and device negotiation outside the callback
- Prefer small C helpers over abstractions that obscure callback behavior
- Match the existing Objective-C naming and ARC style

## Pull Requests

Include:

- The behavior being changed
- Hardware used for testing
- Verification commands run
- Latency or CPU implications
- Any remaining processing boundary or security risk

Keep generated bundles and build directories out of commits.

## Packaging And Installation

```sh
make package
make install
```

Packaging produces `dist/HeadphoneMonitor-macOS.zip` and a SHA-256 sidecar. Installation moves an existing application to a temporary backup before copying the new bundle.
