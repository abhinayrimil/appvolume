# AppVolume

Per-app audio volume control for macOS, built on Apple's public Core Audio
process-tap APIs. Set an independent volume (0–200%) for each running app.

Two front-ends share one engine:

- **CLI** (`main.swift`) — control one app from the terminal, with live arrow-key adjustment.
- **Menu-bar app** (`ui/`) — an AppKit status-bar item with a slider per app that's playing audio.

## Requirements

- macOS 14.3 or later (the process-tap API, `AudioHardwareCreateProcessTap`).
- Apple Command Line Tools (`swiftc`). No Xcode required.
- Apple Silicon or Intel.

On first use macOS asks for audio-capture permission; approve it.

## How it works

For each app you turn away from 100%:

1. A private `CATapDescription` taps the app's output and mutes its normal playback.
2. A private aggregate device is created from the current default output device plus that tap (with drift compensation).
3. An IO proc reads the tapped audio, applies a gain ramp (`vDSP_vrampmul`, click-free), and writes it to the output device.

At exactly 100% no tap is created, so the app is left completely untouched.

Volume uses a perceptual taper: 0→100% maps −64 dB→0 dB (logarithmic); above
100% is linear boost with a `tanh` soft-clip so peaks saturate instead of
clipping hard. The default-output device is watched, so switching outputs
(e.g. plugging in headphones) rebuilds the active taps automatically.

## Build & run

### CLI

```sh
swiftc -O main.swift -o appvolume \
    -framework CoreAudio -framework AudioToolbox -framework Accelerate -framework Foundation

./appvolume <pid|name> <volume 0..2>
# examples
./appvolume Music 0.5      # Music at 50%
./appvolume Music 1.8      # 180% boost
```

Arrow keys adjust the volume live; `q` or Ctrl-C restores the app and quits.

### Menu-bar app

```sh
cd ui
./build.sh                 # produces AppVolume.app
open AppVolume.app
```

Click the menu-bar item (`AV` + speaker). Each app currently playing audio gets
a slider; **Reset** returns it to 100%. Levels are remembered per app across
launches (`UserDefaults`).

> On a notched Mac the menu-bar item can hide behind the notch — move another
> window aside or use an external display if you can't see it.

## Notes

- The app is ad-hoc signed by `build.sh`. If macOS blocks the tap without a
  permission prompt, sign with a real Developer ID instead.
- Written entirely from Apple's public APIs. Not derived from any third-party
  audio app.

## License

MIT
