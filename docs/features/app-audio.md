# App audio

A menu bar mixer: each app playing sound gets a volume slider, a mute button and its own output, and
the header switches the default output. Turn it on in Settings › General › App Audio or with **Toggle
App Audio Mixer**.

## Invariants

- **An untouched app is never tapped.** Only a setting below 100%, muted, or pinned to another output
  installs anything, and a mixer nobody has touched installs no listener either.
- **Every HAL call runs on `AppAudioEngine`'s one serial queue.** Creating or stopping an I/O proc from
  main, or inside a property listener, deadlocks against the HAL and can wedge `coreaudiod`; listeners
  are delivered on a second queue and only hop onto the engine's.
- **`coreaudiod` never asks for the microphone.** Its prompt stalls every app's audio until answered.
  The aggregate holds the tap alone with its rate left alone, playback is a raw I/O proc with input
  off, never an audio unit, and an output with an input side waits for Bestcast's own microphone
  question first.
- **A tapped app is muted at the source and Bestcast plays the copy**, so quitting must hand the audio
  back: `prepareForTermination` calls the synchronous `stopAll()`.
- **Per-app settings stay on this Mac.** `appAudioSettings` travels in neither a backup nor
  settings.json; whether the mixer shows in the menu bar does, as `general.appAudioInMenuBar`.
- **What a slider does and which row a process joins is `Model/`'s call, pure for `app-audio-test`.**

## How a tap plays

`AppAudioTap` takes a private `CATapDescription` of the app's processes with `.mutedWhenTapped`,
wraps it in a private tap-only aggregate, and copies its input into `AudioSampleRing`, a lock-free
single-producer ring. A raw I/O proc on the chosen device, its input streams switched off, reads the
ring at the gain, an atomic word. The device may run at another rate than the tap, so the reader steps
through the ring at their ratio and interpolates between frames; a listener on both rates keeps that
ratio current. The reader never touches a slot past the last one written, and one more than 100 ms
behind skips ahead.

Two obvious routes ask for the microphone and stall `coreaudiod` on the prompt, and with it every
app's audio: a HAL output audio unit, which also binds the default input, and setting the aggregate's
sample rate.

The slider is squared into gain, so half the slider is a quarter of the amplitude, which sounds like
half. Muted is gain 0 at any slider position.

## Rows

`AppAudioGrouping` folds helper processes under the app that owns them by bundle-ID prefix, so a
browser's renderers are one row. A process without a bundle ID, such as `afplay`, is its executable
name. Rows show apps playing now plus any app with a setting, while it runs. The listeners re-route on
new or exiting processes, devices coming and going, a new default and apps launching or quitting; a pinned output that disappears
plays on the default until it returns.

## Permission

Taps need **System Audio Recording**, which macOS asks for with `NSAudioCaptureUsageDescription` the
first time a tap starts. Playing through an output that also has an input side, such as a USB
interface or a headset, is a microphone request to macOS, so before such a tap starts the engine asks
for the microphone itself; allowed or not, the tap then plays. A refused tap reports once per app through a HUD and leaves the app playing untouched.
