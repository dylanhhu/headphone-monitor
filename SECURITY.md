# Security Policy

## Scope

Headphone Monitor is security sensitive because it has microphone access. The intended security model is deliberately small:

- Microphone input is permitted
- Network client and server access is denied by App Sandbox
- User-file access is denied by App Sandbox
- Audio is not recorded or persisted

## Reporting

Use GitHub private vulnerability reporting when it is enabled for the repository. Do not open a public issue containing audio, private logs, device identifiers, or other sensitive data.

Include the affected commit, macOS version, device configuration, and a minimal reproduction with sensitive values removed.

## Out Of Scope

The project cannot prevent processing performed by CoreAudio, an audio driver, Bluetooth, AirPlay, or hardware. It also cannot guarantee behavior after an administrator installs a malicious audio driver or grants the app additional system capabilities.
