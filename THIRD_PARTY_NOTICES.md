# Third-party notices

## Application protocol lineage

ATVV control handling and high-nibble-first IMA ADPCM decoding were adapted
from [Open Voice Bridge](https://github.com/nijez/open-voice-bridge), revision
`1796b149f752ff2d2fa82fd818f8a5a2bc60802a`, GPL-3.0-only, copyright 2026
Open Voice Bridge contributors. The upstream implementation credits
[remote-bridge-hub](https://github.com/xxb26553663-star/remote-bridge-hub),
revision `8a93f321ac71a602300c6cd77f7256fa4b63068e`, GPL-3.0-only.

Our modified implementation targets the RC003-MS retail model, whose device
information service reports RC003 / MIOM / V2.0 / 2671 / A.7.0.6. Its ATVV
service and characteristic topology were observed on the current device. Across
separate connections it returned the complete capability responses
`0b0100000300780000` and `0b0100020300780000`; both describe ATVV v1, codec 2,
16 kHz and 120-byte frames. Local device binding, independent audio and key
controls, per-hold decoding, bounded buffering and dedicated CoreAudio routing
are project modifications. Physical HID input, remote audio packets and the
system end-to-end path remain installation-time tests; this notice does not
claim that they have passed. Original and modification notices are retained.
The full GPLv3 text is in LICENSE.

## Audio driver source

OpenRemoteAudio is an unofficial modification of the GPLv3 source of
[BlackHole](https://github.com/ExistentialAudio/BlackHole), fixed revision
`e2b22aaaba4e507a097131704bf96dabc004d9cf` (v0.7.1).
Copyright 2019–2026 Existential Audio Inc.

The original license, exact source hashes and modifications are documented
under driver/. The driver uses this project's own name, bundle identity and
devices. We do not redistribute the official BlackHole installer, binaries,
icon or package artwork, and do not imply an affiliation or endorsement.
Source-code licensing does not grant additional upstream trademark rights.

The visible-input USB transport compatibility approach was independently
adapted after reviewing [HD838A/remote-mic-app](https://github.com/HD838A/remote-mic-app)
at revision `9e019112fc88534004641499b0b1efc50b491e5e` (GPL-3.0-only). That project
documents a BlackHole-derived USB-reported device for applications that omit
ordinary virtual microphones. OpenRemoteAudio applies the idea only to its
visible input; its hidden writer remains Virtual. No name, identifier, binary,
logo or icon from that project is included.

## Typeless compatibility adaptation

The Typeless compatibility implementation directly adapts source and test
logic from [HD838A/remote-mic-app](https://github.com/HD838A/remote-mic-app),
fixed revision `9e019112fc88534004641499b0b1efc50b491e5e`, GPL-3.0-only,
copyright (C) 2026 SayAll contributors. In particular, the transactional
`UserKeyMapping` policy, software Fn-key injection, and the paired Fn-tap voice
session controller were adapted from the upstream
`RemoteVoiceFunctionMapper.swift`, `KeyboardInjector.swift`,
`VoiceFnTapSessionController.swift`, their integration, and related tests.

This project's modifications bind the transaction to the selected RC003-MS
location and require every matching HID service at that location to map the
physical voice-key F5 usage to usage zero. The complete neutralization is
checked again before every audio stream. Audio is held in a bounded pre-roll
until the opening Fn tap succeeds; after release, queued audio is drained for
at most 0.75 seconds before the closing Fn tap. Generation tracking, cancelled
tasks and explicit shutdown/restore paths isolate rapid consecutive sessions
and clean up on disable, device change, failure and application exit.

This compatibility mode is disabled by default. The user has confirmed the
basic RC003-MS-to-Typeless path on the current test Mac; the full stress and
failure checklist and the added Doubao, WeChat Input and Shandianshuo presets
still require separate physical validation. It uses the main application's macOS Accessibility
permission to post Fn events; it does not require full key mapping, Input
Monitoring, the privileged HID takeover, or its administrator authorization.
The user must still select “遥控器麦克风” as Typeless's input device. No SayAll
or remote-mic-app name, bundle identifier, binary, logo, app icon, brand asset,
or bundled product photo is copied or redistributed by this project.

## Button mapping fallback adaptation

The non-exclusive RC003-MS HID reading and narrowly armed native-event
suppression strategy was adapted from
[HD838A/remote-mic-app](https://github.com/HD838A/remote-mic-app), fixed revision
`9e019112fc88534004641499b0b1efc50b491e5e`, GPL-3.0-only, copyright (C) 2026
SayAll contributors. The relevant upstream implementations are
`HIDRemoteMonitor.swift`, `KeyboardEventSuppressor.swift`, and
`RemoteButtons.swift`.

This project keeps its existing exact local RC003-MS binding, report parser,
held-key state machine and configurable key output. It first attempts exclusive
access; when macOS refuses that operation but permits shared reading, it listens
only to the bound device and arms suppression for the measured native event
corresponding to each just-observed remote edge. Synthetic mapped output is
marked and is not suppressed. This avoids requiring the unsuccessful
administrator/helper input-access path. Physical validation of every button
and suppression edge remains an installation-time acceptance step.

## Apple frameworks

The application uses system-supplied SwiftUI, AppKit, IOKit, CoreBluetooth,
CoreAudio, AudioToolbox and related Apple frameworks. The repository does not
redistribute Apple SDKs, Xcode, signing certificates or private signing keys.

## Assets and excluded components

The default remote control is drawn by SwiftUI. A user can import their own
photo locally; its rights remain with its owner. No user photo, diagnostic
recording, private configuration, screen capture or actual pairing identity
is included in the source or installer payload.

This product does not include Sparkle, Qt/PySide, Frida, VB-CABLE, the upstream
Windows application or its photo. Notices for those unused upstream
components do not represent this product's contents.

## Corresponding source

Any public binary release must provide its matching complete source archive,
including driver source, patches, configuration and installation/build
scripts, alongside the package. A development build is not a notarized public
release. Release assets and their source archive must remain version-matched.
