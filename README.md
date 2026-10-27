# Unmuffle

A free, open-source macOS menu bar app that cleans up bad audio in real time, for
whatever your Mac is playing: a browser tab, a video player, anything.

Built for the worst kind of movie audio: a recording made with a phone or camcorder
in a theater. It's muffled, full of hiss and air-conditioning noise, swimming in room
echo, with dialogue you can barely make out and explosions that blow your ears off.
Unmuffle goes after each of those problems:

| Problem | What Unmuffle does |
| --- | --- |
| Hiss, hum, HVAC, crowd murmur | Spectral noise removal that learns the background noise and subtracts it |
| Big-room echo | Late-reverb suppression that predicts the room's tail and removes it |
| Muffled, mumbly voices | Cuts the boomy low-mids and lifts the speech band; focuses the center channel |
| Dull, "underwater" sound | A harmonic exciter regenerates the high end cheap mics and encoders throw away |
| Thin or mono sound | Bass shelf, plus mid/side widening that turns mono into stereo |
| Whispers vs. explosions | A leveler lifts quiet lines without lifting the noise between them |
| Too quiet overall | Up to +12 dB of boost behind a look-ahead limiter, so it never clips |

Flip between **Original** and **Enhanced** at any time to hear the difference.

> It can't turn a theater recording into the studio mix. Unmuffle makes bad audio
> far easier to listen to. What it can't do is separate a voice from a laugh or cough
> happening at the same moment; that needs machine learning (see the roadmap).

## Requirements

- macOS 14.2 (Sonoma) or later, Apple Silicon or Intel
- Xcode 15+ or the Xcode Command Line Tools, to build it

## Build and run

```sh
git clone <this repo>
cd unmuffle
./scripts/build-app.sh
open build/Unmuffle.app
```

A waveform icon appears in the menu bar. Click it and flip the switch on.

The first time, macOS asks for permission to record system audio. Allow it. That
permission is what lets Unmuffle hear the audio it's cleaning up. Nothing is recorded,
saved or sent anywhere. If you missed the prompt, go to **System Settings → Privacy &
Security → Screen & System Audio Recording → System Audio Recording Only**, enable
Unmuffle, then turn the switch off and on again. (Rebuilding the app can make macOS ask
again, because ad-hoc signed builds get a new identity each time.)

## Using it

1. Start the movie.
2. Turn Unmuffle on and pick a preset:
   - **Cam Recording**: filmed in a theater. Heavy noise, echo, muffled voices.
   - **Line Audio**: decent source, some hiss, flat and thin.
   - **Too Quiet**: clean but quiet, or dialogue buried under the music.
   - **Night Mode**: everything at one volume.
   - **Maximum**: everything cranked.
3. Tweak the sliders if you like. Changes are instant and saved between launches.

While it's on, Unmuffle processes everything your Mac plays, so turn it off when
you're done watching. It adds about 23 ms of delay, well below what you'd notice as
lip-sync drift.

## Fixing a downloaded file

The same engine is available as a command-line tool for WAV files. With
[ffmpeg](https://ffmpeg.org) you can fix a video's audio track and put it back:

```sh
swift build -c release --product unmuffle-cli

ffmpeg -i movie.mp4 -vn -ac 2 -ar 48000 audio.wav
.build/release/unmuffle-cli audio.wav fixed.wav --preset cam
ffmpeg -i movie.mp4 -i fixed.wav -map 0:v -map 1:a -c:v copy -c:a aac -b:a 192k movie-fixed.mp4
```

Run `unmuffle-cli --help` for every option (each slider has a flag), or
`--list-presets`. It processes about 40× faster than real time.

## How it works

```
 every app's audio ──► Core Audio process tap (originals muted)
                              │
                              ▼
   rumble filter → noise + echo removal (STFT) → dialogue EQ → exciter
     → mid/side width → leveler → boost → limiter
                              │
                              ▼
                  your speakers / headphones
```

- **System capture**: a Core Audio [process tap](https://developer.apple.com/documentation/coreaudio/catapdescription)
  (macOS 14.2+) grabs the mix of every app except Unmuffle and mutes the originals.
  A private aggregate device pairs the tap with your current output device, so a single
  callback reads the captured audio and writes the cleaned version. No virtual audio
  driver is needed, and if the app quits or crashes macOS removes the tap and your
  audio comes straight back. Plug in headphones or connect AirPods and it follows.
- **Noise removal**: a short-time Fourier transform (1024 points, 75% overlap)
  with minimum-statistics noise tracking and a decision-directed Wiener gain. Two
  safeguards keep music intact: the noise floor is taken from the quietest neighbouring
  frequencies (room noise is smooth across frequency, notes are peaky), and bins whose
  level barely fluctuates (steady tones) are left alone.
- **Echo removal**: the statistical late-reverb model of Lebart et al., which
  predicts the room's tail from what was playing ~50 ms earlier and subtracts it.
- **Everything else**: biquad EQ, an envelope-normalized harmonic exciter, mid/side
  processing with complementary comb filters for mono-compatible width, a leveler whose
  expander follows the dialogue level, and a look-ahead brick-wall limiter.

The DSP is plain Swift with no Apple-only dependencies. It uses about 2% of one CPU core.

## Project layout

```
Sources/UnmuffleDSP/    the audio engine (cross-platform, fully tested)
Sources/Unmuffle/       the macOS menu bar app (SwiftUI + Core Audio taps)
Sources/unmuffle-cli/   the WAV command-line tool
Tests/UnmuffleDSPTests/ engine tests
scripts/build-app.sh    builds Unmuffle.app
```

## Development

```sh
swift test      # runs on macOS or Linux
```

The tests check the things that matter by ear: hiss drops by more than 12 dB while
speech-like bursts and held musical chords come through within 1 dB; echo tails drop
by more than 6 dB; the leveler lifts quiet lines but not the pauses between them; the
limiter never lets a sample past -1 dBFS; neutral settings and bypass pass audio through unchanged; every
preset stays stable at 44.1, 48 and 96 kHz.

## Roadmap

- Per-app capture (only process the browser, leave notifications alone)
- Machine-learning dialogue isolation (e.g. a Core ML speech-enhancement model) for
  the problems classic DSP can't touch: laughter, coughs, people talking over the movie
- Auto-pick the preset by analyzing the audio
- Launch at login, keyboard shortcut for Original/Enhanced
- Signed and notarized releases

Contributions welcome.

## License

MIT
