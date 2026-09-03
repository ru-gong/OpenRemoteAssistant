# OpenRemoteAudio — source and third-party notice

OpenRemoteAudio is an unofficial, locally built modification of BlackHole source.
It is not an official BlackHole binary or installer, and is not endorsed by
Existential Audio Inc., Apple, or Xiaomi. No official icon, banner, package
artwork, or precompiled driver is included.

- Original source: BlackHole, Copyright (C) 2019 Existential Audio Inc.; the
  upstream LICENSE additionally identifies 2019–2026 Existential Audio Inc.
- Original repository: https://github.com/ExistentialAudio/BlackHole
- Fixed source revision: `e2b22aaaba4e507a097131704bf96dabc004d9cf` (v0.7.1).
- Source license: GNU GPL version 3; the complete original LICENSE, including its
  source/binary/branding distinctions, is preserved as `upstream/LICENSE` in the
  source tree and `LICENSE-BlackHole-source` in the driver bundle.
- Custom code: Copyright (C) 2026 OpenRemote contributors, GPL-3.0-only.
- Modification date and details: see `CHANGES.md`.
- Virtual-microphone enumeration compatibility reference:
  https://github.com/HD838A/remote-mic-app, inspected revision
  `9e019112fc88534004641499b0b1efc50b491e5e`, GPL-3.0-only. This project
  independently applies the transport idea only to its visible input and does
  not reuse that project's name, identifiers, binary, logo or icon.

The GPL text is included as `LICENSE`. There is no warranty except where
separately agreed. Recipients retain the rights granted by the applicable GPL.
Upstream copyright and trademarks remain with their respective owners; this
source attribution is not a grant to reuse upstream branding.

The corresponding source for this local build is the complete `product/driver`
source directory (excluding generated `build/`) together with
`product/scripts/build-driver.zsh`. No private key is required for the default
ad-hoc local build. A public binary release must provide its exact corresponding
source beside the binary download under GPLv3 section 6(d); this local notice
does not claim that a public release or source hosting has already occurred.
