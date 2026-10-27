#!/usr/bin/env python3
"""Measures speech intelligibility (ESTOI) before and after Unmuffle.

Three LibriSpeech readings, each over the same quiet string score, go through the
virtual theater in make_demo.py and then through unmuffle-cli. ESTOI compares each
result against the clean voice (0 = unintelligible, 1 = identical).

usage: score.py <unmuffle-cli> <music> <speech> [<speech> ...] [-- extra cli args]
needs: numpy, scipy, pystoi, ffmpeg
"""
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
from pystoi import stoi

import make_demo as demo


def main():
    args = sys.argv[1:]
    extra = []
    if "--" in args:
        extra = args[args.index("--") + 1:]
        args = args[: args.index("--")]
    cli, music_path, *speech_paths = args
    music = demo.decode(music_path)
    before_scores, after_scores = [], []
    for path in speech_paths:
        demo.rng = np.random.default_rng(7)
        speech = demo.decode(path)
        bed = np.pad(music[: len(speech)], (0, max(0, len(speech) - len(music))))
        speech *= 0.1 / demo.rms(speech)
        bed *= demo.rms(speech) * 10 ** (-15 / 20) / demo.rms(bed)
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            before = demo.through_aac(demo.simulate_cam(speech + bed), work)
            demo.write_wav(work / "before.wav", before)
            subprocess.run([cli, str(work / "before.wav"), str(work / "after.wav"), "--preset", "cam", *extra],
                           check=True, capture_output=True)
            after = demo.decode(work / "after.wav")[: len(before)]
        before_scores.append(stoi(speech, before, demo.RATE, extended=True))
        after_scores.append(stoi(speech, after, demo.RATE, extended=True))
        print(f"{Path(path).name:28s} before {before_scores[-1]:.3f}  after {after_scores[-1]:.3f}")
    b, a = np.mean(before_scores), np.mean(after_scores)
    print(f"{'mean':28s} before {b:.3f}  after {a:.3f}  ({(a / b - 1) * 100:+.0f}%)")


if __name__ == "__main__":
    main()
