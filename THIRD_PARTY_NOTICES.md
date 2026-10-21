# Third-Party Notices

## serve-sim

This project includes code adapted from `EvanBacon/serve-sim`:

https://github.com/EvanBacon/serve-sim

The adapted code is used in SimTool's simulator streaming pipeline, including
direct SimulatorKit framebuffer capture, VideoToolbox H.264 encoding, AVCC
chunk framing, MJPEG fallback encoding, and browser-side AVCC demux/decoding
logic.

SimTool's iPhone Duo support adapts serve-sim's foldable work (at commit
`a30d70a`): choosing the framebuffer to stream from the device type's own
screen sizes (`Tool/Sources/SimToolStream/FramebufferSurfaceSelector.swift`),
each panel's own Indigo touch target (`0x40000000 | screen number`), and the
guest helper that folds the device through a virtual HID hinge
(`Tool/Sources/SimToolCore/SimulatorFold.swift`, from `SimDuoHID/main.m`), and
the 3D preview — loading the device model, scrubbing its fold clip, texturing
its screens and projecting them (`Tool/Sources/SimToolStream/Duo3DRenderer.swift`,
from `DuoRenderer.swift` and `DuoScreenProjection.swift`) and mapping a click
back onto the panel (`pointOnDuoScreen` in `web/js/logic.js`, from
`client/utils/duo-projection.ts`). The 3D preview renders Xcode's own device
model from the user's Xcode at run time; no Apple asset, material table or
private lighting is copied or used.
Facts learned from serve-sim — the panels' sizes and names — are used as facts.

`serve-sim` is licensed under the Apache License, Version 2.0. Copyright
belongs to the original contributors. Modified portions are used under the
terms of Apache-2.0.

## Noora

Noora is provided by Tuist and licensed under the MIT License:

https://github.com/tuist/Noora

## Swifter

Swifter is provided by HTTPSwift and licensed under the MIT License:

https://github.com/httpswift/swifter

## Swift Argument Parser

Swift Argument Parser is provided by Apple and licensed under the Apache
License, Version 2.0:

https://github.com/apple/swift-argument-parser
