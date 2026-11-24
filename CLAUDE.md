# Hush

A noise generator for iPhone built from four principles (Texture, Shape, Motion, Space) instead
of noise colours, with a room-matching mask. Read `README.md` first for what it does and how to run it.

## Layout

- `NoiseKit/` Swift package, no UI. It holds everything that can be tested without a phone.
  - `Model.swift` the saved types: `Sound`, `Layer`, `Texture`, `SpectralShape`, `Motion`, `Space`, `RoomMask`, `RoomProfile`.
  - `Scene.swift` the saved `Soundscape` (train, fireplace) and its slider list. `SceneKernel.swift` plays it on
    the audio thread from separate events (rail-joint hits, crackles); `NoiseKernel.render` adds it after the layers.
  - `NoiseKernel.swift` runs on the audio thread. `NoiseSynth.swift` is its front: it designs filters on a
    background queue and hands them over.
  - `FilterDesigner.swift` turns a shape into a minimum-phase filter. `Spectrum.swift` computes the curves the
    plot draws, from the same shape code the filters use, so the plot and the sound cannot disagree.
  - `RoomAnalyzer.swift` measures a recording into 61 bands. `TestRoom` is the made-up room for the Simulator.
- `Hush/` the app. One screen (`Views/MixScreen.swift`) and two sheets.
  - `Audio/Player.swift` owns `AVAudioEngine` and the audio session. `Audio/RoomListener.swift` owns the microphone.
  - `Model/AppModel.swift` is the single observable model. `Model/Library.swift` saves to
    Application Support/Hush/library.json and holds the starting points.
- `project.yml` xcodegen. `Hush.xcodeproj` is generated and not in git.

## Rules

- Commit only when Patrick asks. Nothing has been committed yet.
- The starting points are the ones Patrick kept after listening: Deep static, Rumble, Low rumble, Vacuum, Submarine, Ship's cabin, Waves, Distant surf, Propeller plane,
  Space station, Air conditioning. He rejected ticks (rain, fire), wind, a fan, brighter statics, plane cabins
  and a distant jet. Ask before adding more, and never use ticks (the Texture density slider) in a starting point.
- Scenes are switched OFF with `Features.scenes` in `Model/Library.swift`: Patrick heard them and said neither
  sounds real (train like a toy, fire pops not like wood). The code and tests stay. Turn the flag on to work on them.
- Scenes (`StartingPoints.scenes`: Train to somewhere, Fireplace) are a separate section Patrick asked for. Their
  events come from `SceneKernel`, not from ticks. Other scene ideas offered and not yet asked for: sleeper cabin,
  heartbeat, engine room, tumble dryer, far thunder, storm from inside a cabin.
- A scene's level sets its loudest moments, not its RMS. Keep peaks under 0.8 at level -20 (a test checks it).
- To look at a scene without ears: `HUSH_RENDER_DIR=<folder> swift test ... --filter sceneAtItsDefaults` writes
  raw float32 renders there; plot a spectrogram and a 10 ms loudness curve from them.
- Run `xcodegen generate` after adding or removing Swift files.
- Nothing on the audio thread may allocate, lock or call Swift runtime code that can. That is everything
  reached from `NoiseKernel.render`, `SceneKernel` included. No array literals, no closures that capture, no `print`.
- The microphone recording is measured and dropped. Never write samples to disk or send them anywhere.
- Build output stays off the internal drive. Xcode's DerivedData is already on 9100PRO. `swift test` needs
  `--scratch-path` (see Commands) or it writes `.build` into the project.
- Do not approve a macOS microphone prompt for the Simulator. That choice is Patrick's.
- Nobody can listen from here. After changing the engine, check it with the tests, and say plainly that
  it has not been heard.

## Conventions

- Words in the app are plain and short. Every slider has a line saying what it does. No noise-colour names
  in the UI: a colour is a tilt value.
- Units shown to the user: dB, dB/octave, Hz, per second, octaves. `Model/Describe.swift` formats all of them.
- The type is `SpectralShape`, not `Shape`, because SwiftUI has a `Shape`.
- Saved sounds are Codable JSON. Add optional fields with defaults; do not rename or remove fields.
- The plot is power density (dB per Hz) on a log frequency axis, 10 dB per gridline, so tilt is the line's slope.
- A change to a level, swell, width or rate reaches the kernel as plain numbers. A new filter is designed
  only when the shape, the resonance, the sweep or the room mask changes (`FilterKey` in `NoiseSynth.swift`).

## Commands

```bash
xcodegen generate
xcodebuild -project Hush.xcodeproj -scheme Hush -destination 'platform=iOS Simulator,name=iPhone 17' build
cd NoiseKit && swift test --scratch-path /Volumes/9100PRO/Developer/Xcode/DerivedData/Hush-NoiseKit-spm
# On Patrick's iPhone: build Release (the audio code must be optimised), then install and open.
# <phone> is the phone's identifier from `xcrun devicectl list devices`.
xcodebuild -project Hush.xcodeproj -scheme Hush -configuration Release -destination 'platform=iOS,id=<phone>' -allowProvisioningUpdates build
xcrun devicectl device install app --device <phone> <DerivedData>/Hush-*/Build/Products/Release-iphoneos/Hush.app
xcrun devicectl device process launch --device <phone> com.pats.hush
swift scripts/make-icon.swift Hush/Assets.xcassets/AppIcon.appiconset/icon.png
```
