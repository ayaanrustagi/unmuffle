// Engine tests for the JavaScript port. Run with: node --test extension/test
//
// Set UNMUFFLE_CLI to the Swift command-line tool to also check that the JS engine
// produces the same audio as the Swift one.

import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Enhancer, NEUTRAL, PRESETS, clampSettings, matchingPreset, decibelsToGain } from "../dsp.js";

const RATE = 48000;

/** Deterministic unit-variance Gaussian noise (SplitMix64-style hash + Box-Muller). */
function noise(seed) {
  let state = BigInt(seed);
  const uniform = () => {
    state = (state + 0x9e3779b97f4a7c15n) & 0xffffffffffffffffn;
    let z = state;
    z = ((z ^ (z >> 30n)) * 0xbf58476d1ce4e5b9n) & 0xffffffffffffffffn;
    z = ((z ^ (z >> 27n)) * 0x94d049bb133111ebn) & 0xffffffffffffffffn;
    z ^= z >> 31n;
    return (Number(z >> 11n) + 0.5) / 2 ** 53;
  };
  return () => Math.sqrt(-2 * Math.log(uniform())) * Math.cos(2 * Math.PI * uniform());
}

const power = (x, from = 0, to = x.length) => {
  let sum = 0;
  for (let i = from; i < to; i++) sum += x[i] * x[i];
  return sum / Math.max(to - from, 1);
};
const db = (p) => 10 * Math.log10(Math.max(p, 1e-20));

function enhance(enhancer, left, right, chunk = 128) {
  const l = Float32Array.from(left), r = Float32Array.from(right);
  for (let offset = 0; offset < l.length; offset += chunk) {
    const end = Math.min(offset + chunk, l.length);
    enhancer.process(l.subarray(offset, end), r.subarray(offset, end), end - offset);
  }
  return [l, r];
}

test("neutral settings are transparent apart from latency", () => {
  const n = noise(2);
  const left = Float32Array.from({ length: RATE }, () => 0.1 * n());
  const right = Float32Array.from({ length: RATE }, () => 0.1 * n());
  const enhancer = new Enhancer(RATE, NEUTRAL);
  const [l, r] = enhance(enhancer, left, right);
  let worst = 0;
  for (let i = enhancer.latency; i < left.length; i++) {
    worst = Math.max(worst, Math.abs(l[i] - left[i - enhancer.latency]), Math.abs(r[i] - right[i - enhancer.latency]));
  }
  assert.ok(worst < 1e-4, `worst error ${worst}`);
});

test("bypass is the delayed original", () => {
  const n = noise(3);
  const left = Float32Array.from({ length: 24000 }, () => 0.3 * n());
  const enhancer = new Enhancer(RATE, { ...PRESETS[0].settings, isEnabled: false });
  const [l] = enhance(enhancer, left, left);
  for (let i = enhancer.latency; i < left.length; i++) assert.equal(l[i], left[i - enhancer.latency]);
});

test("removes hiss but keeps speech-like bursts, in mono and stereo", () => {
  for (const mono of [false, true]) {
    const n = noise(4);
    const total = RATE * 8, segment = RATE / 4;
    const left = new Float32Array(total), right = new Float32Array(total);
    for (let i = 0; i < total; i++) {
      const tone = Math.floor(i / segment) % 2 === 0 ? 0.1 * Math.sin((2 * Math.PI * 1000 * i) / RATE) : 0;
      left[i] = tone + 0.003 * n();
      right[i] = mono ? left[i] : tone + 0.003 * n();
    }
    const enhancer = new Enhancer(RATE, { ...NEUTRAL, noiseReduction: 0.8 });
    const [out] = enhance(enhancer, left, right);
    let inOn = 0, outOn = 0, inOff = 0, outOff = 0;
    for (let s = total / segment / 2; s < total / segment - 1; s++) {
      const start = s * segment + segment / 5, end = (s + 1) * segment - segment / 5;
      const pin = power(left, start, end), pout = power(out, start + enhancer.latency, end + enhancer.latency);
      if (s % 2 === 0) { inOn += pin; outOn += pout; } else { inOff += pin; outOff += pout; }
    }
    assert.ok(db(outOff) - db(inOff) < -12, `hiss change ${db(outOff) - db(inOff)} (mono=${mono})`);
    assert.ok(db(outOn) - db(inOn) > -1, `tone change ${db(outOn) - db(inOn)} (mono=${mono})`);
  }
});

test("limiter holds -1 dBFS with the loudest preset", () => {
  const left = Float32Array.from({ length: RATE * 2 }, (_, i) => 2.5 * Math.sin((2 * Math.PI * 220 * i) / RATE));
  const right = Float32Array.from({ length: RATE * 2 }, (_, i) => 2 * Math.sin((2 * Math.PI * 330 * i) / RATE));
  const [l, r] = enhance(new Enhancer(RATE, PRESETS.at(-1).settings), left, right);
  const ceiling = decibelsToGain(-1) + 1e-6;
  for (let i = 0; i < l.length; i++) assert.ok(Math.abs(l[i]) <= ceiling && Math.abs(r[i]) <= ceiling);
});

test("every preset stays finite at common sample rates", () => {
  for (const preset of PRESETS) {
    for (const rate of [44100, 48000, 96000]) {
      const n = noise(6);
      const left = Float32Array.from({ length: rate }, (_, i) => (i < rate / 2 ? 0 : 0.5 * n()));
      const [l, r] = enhance(new Enhancer(rate, preset.settings), left, left.slice());
      assert.ok(l.every(Number.isFinite) && r.every(Number.isFinite), `${preset.id} @ ${rate}`);
      assert.ok(power(l, (rate * 3) / 4) > 1e-4, `${preset.id} @ ${rate} went silent`);
    }
  }
});

test("settings are clamped and presets are recognised", () => {
  const s = clampSettings({ noiseReduction: NaN, width: 7, boostDB: -40 });
  assert.equal(s.noiseReduction, 0);
  assert.equal(s.width, 1);
  assert.equal(s.boostDB, 0);
  for (const preset of PRESETS) assert.equal(matchingPreset(preset.settings), preset);
});

// MARK: - Same audio as the Swift engine

function writeWav(path, left, right) {
  const frames = left.length, dataSize = frames * 8;
  const buffer = Buffer.alloc(44 + dataSize);
  buffer.write("RIFF", 0); buffer.writeUInt32LE(36 + dataSize, 4); buffer.write("WAVE", 8);
  buffer.write("fmt ", 12); buffer.writeUInt32LE(16, 16); buffer.writeUInt16LE(3, 20); buffer.writeUInt16LE(2, 22);
  buffer.writeUInt32LE(RATE, 24); buffer.writeUInt32LE(RATE * 8, 28); buffer.writeUInt16LE(8, 32); buffer.writeUInt16LE(32, 34);
  buffer.write("data", 36); buffer.writeUInt32LE(dataSize, 40);
  for (let i = 0; i < frames; i++) {
    buffer.writeFloatLE(left[i], 44 + i * 8);
    buffer.writeFloatLE(right[i], 48 + i * 8);
  }
  writeFileSync(path, buffer);
}

function readWav(path) {
  const buffer = readFileSync(path);
  const frames = buffer.readUInt32LE(40) / 8;
  const left = new Float32Array(frames), right = new Float32Array(frames);
  for (let i = 0; i < frames; i++) {
    left[i] = buffer.readFloatLE(44 + i * 8);
    right[i] = buffer.readFloatLE(48 + i * 8);
  }
  return [left, right];
}

test("matches the Swift engine", { skip: !process.env.UNMUFFLE_CLI && "set UNMUFFLE_CLI to compare" }, () => {
  const n = noise(9);
  const frames = RATE * 4;
  const left = new Float32Array(frames), right = new Float32Array(frames);
  for (let i = 0; i < frames; i++) {
    const t = i / RATE;
    const pitch = 140 + 30 * Math.sin(2 * Math.PI * 0.7 * t);
    let voice = 0;
    for (let h = 1; h <= 12; h++) voice += Math.sin(2 * Math.PI * pitch * h * t) / h;
    const gate = Math.sin(2 * Math.PI * 3 * t) > 0 ? 1 : 0;
    left[i] = 0.08 * voice * gate + 0.01 * n();
    right[i] = 0.08 * voice * gate + 0.01 * n();
  }
  const dir = mkdtempSync(join(tmpdir(), "unmuffle-"));
  writeWav(join(dir, "in.wav"), left, right);
  execFileSync(process.env.UNMUFFLE_CLI, [join(dir, "in.wav"), join(dir, "out.wav"), "--preset", "cam"]);
  const [swiftLeft] = readWav(join(dir, "out.wav"));

  // Same procedure as unmuffle-cli: pad by the latency, process in 512s, drop the latency.
  const enhancer = new Enhancer(RATE, PRESETS[0].settings);
  const padded = (x) => Float32Array.from({ length: frames + enhancer.latency }, (_, i) => (i < frames ? x[i] : 0));
  const [jsLeft] = enhance(enhancer, padded(left), padded(right), 512);
  const js = jsLeft.subarray(enhancer.latency);

  let signal = 0, error = 0;
  for (let i = 0; i < frames; i++) {
    signal += swiftLeft[i] * swiftLeft[i];
    error += (swiftLeft[i] - js[i]) ** 2;
  }
  const differenceDB = 10 * Math.log10(error / signal);
  console.log(`JS vs Swift difference: ${differenceDB.toFixed(1)} dB`);
  assert.ok(differenceDB < -40, `JS and Swift differ by ${differenceDB.toFixed(1)} dB`);
});
