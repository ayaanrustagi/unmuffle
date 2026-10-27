# Unmuffle for Chrome

The same engine as the Mac app, running in your browser: it captures the current tab's
audio, cleans it up and plays it back. Works on any site and any video player.

## Install

1. Download **Unmuffle-Chrome.zip** from the
   [latest release](https://github.com/ayaanrustagi/unmuffle/releases/latest) and unzip it
   (or use this folder from a clone).
2. Open `chrome://extensions`, turn on **Developer mode** (top right), click **Load
   unpacked** and pick the unzipped folder.
3. Pin Unmuffle to the toolbar, open a tab that's playing something, click the icon and
   hit the power button. The toolbar icon shows **ON** while it's working.

Works in Chrome, Edge, Brave, Arc and other Chromium browsers (version 116+).

## How it works

- `popup.*`: the UI. Asks Chrome for a capture of the current tab (`chrome.tabCapture`).
- `background.js`: tracks which tab is on and owns the offscreen document.
- `offscreen.*`: turns the capture into a Web Audio graph. Capturing a tab mutes it, so
  you only hear the cleaned-up version.
- `worklet.js` and `dsp.js`: the engine, a line-for-line port of the Swift one in
  `Sources/UnmuffleDSP`, running in an `AudioWorklet`.

One tab at a time; turning it on in another tab moves it there. Chrome doesn't allow
capturing its own pages (`chrome://`, the Web Store).

## Tests

```sh
node --test "extension/test/*.test.js"
```

With `UNMUFFLE_CLI` pointing at the Swift command-line tool, the tests also check that
both engines produce the same audio (they agree to within -80 dB).
