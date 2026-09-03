# OpenRemoteAudio changes

2026-09-02 — OpenRemote contributors, local version 0.1.1, GPL-3.0-only.

The files in `upstream/` are unmodified pinned copies from BlackHole revision
`e2b22aaaba4e507a097131704bf96dabc004d9cf`. SHA-256 pins are checked before every
build. `Sources/OpenRemoteAudio.c` includes that original source and adapts the
exported AudioServerPlugIn property interface; it does not rewrite the original.

- Own driver, factory, bundle and device identities; own manufacturer label.
- One visible input-only device named 遥控器麦克风 and one hidden output-only
  mirror, both with two Float32 PCM channels; shared 16/44.1/48 kHz support.
- The visible input reports USB transport metadata so clients that exclude
  ordinary Virtual devices can enumerate it. The hidden application writer
  remains Virtual. This is a compatibility label only: no physical USB device
  is claimed and the audio path is still the same in-memory loopback.
- Visible input may be explicitly selected as default input. Hidden output is
  ineligible for default playback; neither device advertises system-effects
  output eligibility. The driver makes no system-default setter call.
- No upstream branding resources. The optional device icon property is absent.
- Correct UID qualifier-size validation for device/box lookup, so a hidden
  endpoint can be resolved through the standard UID translation property.
- Explicit plugin bundle ID and own plugin/box manufacturer/name metadata.
- Correct plugin-owned-object list and box-device list for both endpoints.
- Correct output stream/control owners to point at the hidden output device.
- A small local CFPlugIn test supplies an in-memory mock host and directly tests
  driver metadata and bounded synthetic PCM callbacks. It does not install the
  driver, call the system AudioObject API, or open a system audio stream.
- A self-contained clang build creates only a local arm64 bundle, default ad-hoc
  signature, test log and hash manifest. Production signing is optional and
  explicit; installation, notarization and publishing are outside this script.

The original ring-buffer/PCM implementation remains upstream code. Offline
roundtrips cannot establish that CoreAudio on a real installed system will load
the bundle or that every receiving application will work. Those require a later
explicitly authorized installation and end-to-end test.

The public-input transport approach was independently adapted after reviewing
HD838A/remote-mic-app at revision `9e019112fc88534004641499b0b1efc50b491e5e`.
That GPL-3.0-only project uses a USB-reported BlackHole-derived device for
clients such as Doubao. OpenRemoteAudio keeps its own split topology, names,
identifiers and implementation.
