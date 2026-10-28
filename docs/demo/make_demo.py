#!/usr/bin/env python3
"""Builds the before/after demo in the README.

A clean voice over a quiet string score is "recorded from the seats" of a virtual
theater (room echo, air conditioning, preamp hiss, phone-mic tone, low-bitrate AAC),
then cleaned up with unmuffle-cli. Both results are loudness-matched so the comparison
is about clarity, not volume.

usage: make_demo.py <speech> <music> <unmuffle-cli> <out-dir>
needs: numpy, scipy, matplotlib, ffmpeg
"""
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
from scipy import signal

RATE = 48_000
rng = np.random.default_rng(7)


def decode(path):
    raw = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", str(path), "-ac", "1", "-ar", str(RATE), "-f", "f32le", "-"],
        check=True, capture_output=True,
    ).stdout
    return np.frombuffer(raw, dtype="<f4").astype(np.float64)


def write_wav(path, mono):
    stereo = np.repeat(mono[:, None], 2, axis=1).astype("<f4")
    subprocess.run(
        ["ffmpeg", "-v", "error", "-y", "-f", "f32le", "-ar", str(RATE), "-ac", "2", "-i", "-",
         "-c:a", "pcm_f32le", str(path)],
        input=stereo.tobytes(), check=True,
    )


def rms(x):
    return np.sqrt(np.mean(x ** 2) + 1e-20)


def peaking(freq, q, gain_db):
    a = 10 ** (gain_db / 40)
    w0 = 2 * np.pi * freq / RATE
    alpha = np.sin(w0) / (2 * q)
    b = [1 + alpha * a, -2 * np.cos(w0), 1 - alpha * a]
    den = [1 + alpha / a, -2 * np.cos(w0), 1 - alpha / a]
    return np.array(b) / den[0], np.array(den) / den[0]


def theater_impulse_response():
    """Direct sound, a handful of early reflections, then a 1.1 s diffuse tail."""
    rt60 = 1.1
    n = int(rt60 * RATE * 1.3)
    t = np.arange(n) / RATE
    tail = rng.standard_normal(n) * 10 ** (-3 * t / rt60)
    tail[: int(0.025 * RATE)] = 0
    tail = signal.sosfilt(signal.butter(2, 4500, "low", fs=RATE, output="sos"), tail)
    # From the back rows the room is louder than the screen: reverb ~4 dB over direct.
    tail *= np.sqrt(2.5 / np.sum(tail ** 2))
    ir = tail
    for delay, gain in [(0.0, 1.0), (0.011, 0.55), (0.019, 0.45), (0.031, 0.4), (0.044, 0.33), (0.058, 0.28)]:
        ir[int(delay * RATE)] += gain
    return ir


def simulate_cam(clean):
    room = signal.fftconvolve(clean, theater_impulse_response())[: len(clean)]
    # Phone mic at a distance: no lows, no highs, a boomy low-mid bump.
    mic = signal.sosfilt(signal.butter(2, 160, "high", fs=RATE, output="sos"), room)
    mic = signal.sosfilt(signal.butter(8, 6500, "low", fs=RATE, output="sos"), mic)
    mic = signal.lfilter(*peaking(300, 1.0, 4.5), mic)
    level = rms(clean)
    hvac = signal.lfilter([1], [1, -0.985], rng.standard_normal(len(clean)))
    hvac = signal.sosfilt(signal.butter(2, 60, "high", fs=RATE, output="sos"), hvac)
    hvac *= level * 10 ** (-24 / 20) / rms(hvac)
    hiss = rng.standard_normal(len(clean)) * level * 10 ** (-38 / 20)
    cam = mic + hvac + hiss
    return 0.9 * cam / np.max(np.abs(cam))


def through_aac(mono, workdir):
    wav, m4a = workdir / "pre.wav", workdir / "cam.m4a"
    write_wav(wav, mono)
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(wav), "-ac", "1", "-c:a", "aac", "-b:a", "48k", str(m4a)], check=True)
    out = decode(m4a)
    return out[: len(mono)]


def to_mp3(mono, path):
    with tempfile.TemporaryDirectory() as tmp:
        wav = Path(tmp) / "x.wav"
        write_wav(wav, mono)
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(wav), "-ac", "1", "-c:a", "libmp3lame", "-b:a", "128k", str(path)], check=True)


def spectrogram_figure(before, after, path):
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.colors import LinearSegmentedColormap

    cmap = LinearSegmentedColormap.from_list("unmuffle", ["#0f0e15", "#2a2266", "#6c4dff", "#ffffff"])
    plt.rcParams["font.family"] = ["Inter", "DejaVu Sans"]
    fig, axes = plt.subplots(2, 1, figsize=(12, 6.6), dpi=160, sharex=True)
    fig.patch.set_facecolor("#0f0e15")
    labels = [("Before", "simulated theater recording: echo, AC noise, hiss, phone mic"),
              ("After", "Unmuffle, Cam Recording preset")]
    for ax, audio, (title, subtitle) in zip(axes, [before, after], labels):
        f, t, s = signal.spectrogram(audio, fs=RATE, nperseg=2048, noverlap=1536, window="hann")
        db = 10 * np.log10(s + 1e-14)
        db -= db.max()
        ax.pcolormesh(t, f / 1000, db, cmap=cmap, vmin=-85, vmax=0, shading="auto", rasterized=True)
        ax.set_ylim(0, 12)
        ax.set_facecolor("#0f0e15")
        ax.tick_params(colors="#8f8aa3", labelsize=9)
        for spine in ax.spines.values():
            spine.set_visible(False)
        ax.set_ylabel("kHz", color="#8f8aa3", fontsize=9)
        ax.text(0.01, 0.93, title, transform=ax.transAxes, color="white", fontsize=15, fontweight="bold", va="top")
        ax.text(0.01, 0.80, subtitle, transform=ax.transAxes, color="#c9c4dc", fontsize=10, va="top")
    axes[-1].set_xlabel("seconds", color="#8f8aa3", fontsize=9)
    fig.tight_layout(pad=1.2)
    fig.savefig(path, facecolor=fig.get_facecolor(), pil_kwargs={"quality": 90})


def main():
    speech_path, music_path, cli, out_dir = sys.argv[1:5]
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)

    speech = decode(speech_path)
    music = decode(music_path)[: len(speech)]
    music = np.pad(music, (0, len(speech) - len(music)))
    fade = np.minimum(1, np.minimum(np.arange(len(music)), np.arange(len(music))[::-1]) / RATE)
    speech *= 0.1 / rms(speech)
    music *= fade * rms(speech) * 10 ** (-15 / 20) / rms(music)
    clean = speech + music

    with tempfile.TemporaryDirectory() as tmp:
        workdir = Path(tmp)
        before = through_aac(simulate_cam(clean), workdir)
        write_wav(workdir / "before.wav", before)
        subprocess.run([cli, str(workdir / "before.wav"), str(workdir / "after.wav"), "--preset", "cam"], check=True)
        after = decode(workdir / "after.wav")[: len(before)]

    # Loudness-match so the comparison is about clarity, not volume.
    target = min(rms(before) * 0.89 / np.max(np.abs(before)), rms(after) * 0.89 / np.max(np.abs(after)))
    before *= target / rms(before)
    after *= target / rms(after)

    to_mp3(before, out / "before.mp3")
    to_mp3(after, out / "after.mp3")
    spectrogram_figure(before, after, out / "before-after.jpg")
    print("wrote", ", ".join(str(out / name) for name in ["before.mp3", "after.mp3", "before-after.jpg"]))


if __name__ == "__main__":
    main()
