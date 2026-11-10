# Changelog

All notable changes are documented here.

## Unreleased

- Add a per-device minimum buffer request for the lowest legal HAL buffer size
- Remove the bridge scratch copy, target prefill from both callback sizes, and trim stale prefill
- Explore optional ultra-low-latency noise rejection within the real-time callback budget
- Add callback deadline, cadence, bridge, underrun, drift, and CoreAudio overload monitoring
- Add explicit INFO, OK, WARN, and ERROR states with status-icon severity

## 0.1.0 - 2026-11-10

- Add native Objective-C menu-bar application
- Add direct CoreAudio HAL callback for same-device monitoring
- Add lock-free bridge for separate input and output devices
- Add exact sample-rate validation and configurable buffer sizes
- Add App Sandbox configuration with microphone input only
- Add build, verification, packaging, and installation tooling
- Add architecture and contribution documentation
