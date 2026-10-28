<p align="center">
  <img src="docs/images/icon.png" width="128" alt="">
</p>

<h1 align="center">Unmuffle</h1>

<p align="center">
  Real-time cleanup for bad video audio, on macOS and in Chrome.<br>
  Removes background noise and room echo, brings dialogue forward, evens out the volume.
</p>

<p align="center">
  <a href="https://github.com/ayaanrustagi/unmuffle/actions/workflows/ci.yml"><img src="https://github.com/ayaanrustagi/unmuffle/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT license"></a>
</p>

<p align="center">
  <img src="https://raw.githubusercontent.com/ayaanrustagi/unmuffle/screenshots/window-light.png" width="320" alt="The Unmuffle menu bar window in light mode">
  &nbsp;&nbsp;
  <img src="https://raw.githubusercontent.com/ayaanrustagi/unmuffle/screenshots/window-dark.png" width="320" alt="The Unmuffle menu bar window in dark mode">
</p>

Unmuffle sits in the menu bar and cleans up everything your Mac plays: a browser tab, a
video player, anything. It's built for recordings made in a room, like a phone at the
back of a theater, where the dialogue is buried under hiss, air conditioning and echo.

The screenshots above are rendered from the app by CI on every push.

## What it does

- **Noise removal.** Learns the steady background (hiss, hum, air conditioning) and
  subtracts it: about 16 dB on the Cam preset, while speech and held music notes come
  through within 1 dB.
- **Echo removal.** Predicts the room's reverb tail from what played ~50 ms earlier and
  removes it, so words stop smearing together.
- **Dialogue.** Cuts low-mid boom, lifts the speech band and narrows the sides, where
  room sound and audience noise live.
- **Clarity.** Regenerates the high end that cheap microphones and low bitrates throw away.
- **Leveling.** Brings quiet lines up without lifting the noise between them.
- **Boost.** Up to +12 dB behind a look-ahead limiter, so it never clips.

Switch between Original and Enhanced at any time. The analyzer shows what comes in (gray)
and what you hear (blue).

## Before and after

<p align="center">
  <img src="docs/demo/before-after.jpg" alt="Spectrogram of the demo recording before and after Unmuffle">
</p>

[before.mp3](docs/demo/before.mp3) and [after.mp3](docs/demo/after.mp3): a LibriSpeech
reading over a quiet string score, run through a simulated theater (1.1 s reverb,
air-conditioning rumble, preamp hiss, phone-mic EQ, 48 kbps AAC), then through the Cam
preset. Both files are loudness-matched.

On this recording, speech intelligibility measured with
[ESTOI](https://github.com/mpariente/pystoi) goes from 0.16 to 0.22 (+33%), averaged
over three voices. [`docs/demo/score.py`](docs/demo/score.py) reproduces it.

## Install

Needs macOS 14.2 or later.

```sh
git clone https://github.com/ayaanrustagi/unmuffle.git
cd unmuffle
./scripts/build-app.sh       # Xcode or the Command Line Tools
open build/Unmuffle.app
```

Click the waveform in the menu bar and turn it on. macOS asks for permission to record
system audio the first time; that is how Unmuffle hears what it cleans up. Nothing is
saved or sent anywhere. If you dismissed the prompt, enable Unmuffle under **System
Settings → Privacy & Security → Screen & System Audio Recording → System Audio Recording
Only**, then switch it off and on.

Builds from each push to `main` are also available as an artifact on the
[CI runs](https://github.com/ayaanrustagi/unmuffle/actions/workflows/ci.yml). They're
unsigned, so macOS will ask you to approve them under Privacy & Security the first time.

## Chrome extension

<p align="center">
  <img src="docs/images/chrome.png" width="640" alt="The Unmuffle Chrome extension in light and dark mode">
</p>

The same engine, ported line for line to JavaScript, for Chrome, Edge, Brave, Arc and
other Chromium browsers (116+) on any OS. It captures the current tab, cleans it up and
plays it back. CI checks that the JavaScript and Swift engines produce the same audio.

1. Go to `chrome://extensions` and turn on **Developer mode**.
2. Click **Load unpacked** and pick the `extension` folder of this repository.
3. On a tab that's playing something, click the Unmuffle icon and turn it on.

More in [extension/README.md](extension/README.md).

## Presets

| Preset | For |
| --- | --- |
| Cam Recording | Filmed in a theater: noise, echo, muffled voices |
| Line Audio | Decent source with some hiss and flat, thin sound |
| Too Quiet | Clean but too quiet, or dialogue buried in music |
| Night Mode | One steady volume, clear voices, tamed explosions |
| Maximum | Everything up, for the worst recordings |

Each stage can be adjusted under **Adjust**. Settings are remembered.

## Fix a downloaded file

The engine also ships as a command-line tool for WAV files. With
[ffmpeg](https://ffmpeg.org) you can clean up a video's audio track and put it back:

```sh
swift build -c release --product unmuffle-cli

ffmpeg -i movie.mp4 -vn -ac 2 -ar 48000 audio.wav
.build/release/unmuffle-cli audio.wav fixed.wav --preset cam
ffmpeg -i movie.mp4 -i fixed.wav -map 0:v -map 1:a -c:v copy -c:a aac -b:a 192k movie-fixed.mp4
```

`unmuffle-cli --help` lists every option. It runs about 50 times faster than real time.

## How it works

```
every app's audio ──► Core Audio process tap (originals muted)
                             │
  rumble filter → noise + echo removal (STFT) → dialogue EQ → exciter
    → mid/side → leveler → boost → limiter
                             │
                 your speakers or headphones
```

- **Capture.** A Core Audio [process tap](https://developer.apple.com/documentation/coreaudio/catapdescription)
  (macOS 14.2+) takes the mix of every app except Unmuffle and mutes the originals. A
  private aggregate device pairs the tap with the current output device, so one callback
  reads the audio and writes the cleaned version. No audio driver to install. If the app
  quits or crashes, macOS removes the tap and the original audio comes straight back.
- **Noise.** A 1024-point STFT with 75% overlap, minimum-statistics noise tracking and a
  decision-directed Wiener gain. The noise floor is taken from the quietest neighbouring
  frequencies and steady tones are left alone, which keeps held music notes intact.
- **Echo.** The statistical late-reverb model of Lebart et al., with spectral subtraction.
- **Everything else.** Biquad EQ, an envelope-normalized harmonic exciter, mid/side
  processing with complementary comb filters for mono-compatible width, a leveler whose
  expander follows the dialogue level, and a look-ahead limiter.

The engine is plain Swift with no dependencies. It uses about 2% of one CPU core and adds
23 ms of delay.

## Limitations

- It can't separate a voice from a laugh or cough happening at the same moment. That
  needs a machine-learning model.
- Echo removal softens very long held notes slightly. Turn Echo down for concerts.
- The Mac app processes all system audio while it's on, notifications included.

## Development

```
Sources/UnmuffleDSP/     audio engine (Swift, cross-platform)
Sources/Unmuffle/        menu bar app (SwiftUI, Core Audio)
Sources/unmuffle-cli/    WAV command-line tool
Tests/UnmuffleDSPTests/  engine tests
extension/               Chrome extension (JavaScript engine and tests)
docs/demo/               demo generator and intelligibility scoring
```

```sh
swift test                                # engine tests, macOS or Linux
node --test "extension/test/*.test.js"    # extension engine tests
```

The tests check that hiss drops by more than 12 dB while speech-like bursts and held
chords stay within 1 dB, that echo tails drop by more than 6 dB, that the leveler lifts
quiet lines but not the pauses between them, that output never exceeds −1 dBFS, and that
every preset is stable at 44.1, 48 and 96 kHz.

## Credits

Process-tap details from [AudioCap](https://github.com/insidegui/AudioCap) and
[FineTune](https://github.com/ronitsingh10/FineTune). Demo audio credits are in
[CREDITS.md](CREDITS.md).

## License

[MIT](LICENSE)
