// Unmuffle audio engine, JavaScript edition.
//
// A line-for-line port of Sources/UnmuffleDSP (Swift) so the Chrome extension sounds
// the same as the Mac app. Keep the two in sync; extension/test/dsp.test.js checks the
// JS output against the Swift command-line tool.

const FLOAT_MAX = 3.4028234663852886e38;

export const decibelsToGain = (db) => Math.pow(10, db / 20);
const gainToDecibels = (gain) => 20 * Math.log10(Math.max(gain, 1e-9));
const smoothingCoefficient = (seconds, sampleRate) => (seconds > 0 ? Math.exp(-1 / (seconds * sampleRate)) : 0);
const clamp01 = (x) => (Number.isFinite(x) ? Math.min(Math.max(x, 0), 1) : 0);

// MARK: - Settings and presets

export const BOOST_RANGE = [0, 12];

export const NEUTRAL = Object.freeze({
  isEnabled: true, noiseReduction: 0, dereverb: 0, dialogue: 0, clarity: 0,
  bass: 0, width: 0, leveling: 0, boostDB: 0,
});

const preset = (id, name, shortName, summary, values) =>
  Object.freeze({ id, name, shortName, summary, settings: Object.freeze({ isEnabled: true, ...values }) });

export const PRESETS = Object.freeze([
  preset("cam", "Cam Recording", "Cam", "Filmed in a theater: noise, echo, muffled voices.", {
    noiseReduction: 0.7, dereverb: 0.75, dialogue: 0.7, clarity: 0.55, bass: 0.35, width: 0.45, leveling: 0.7, boostDB: 6,
  }),
  preset("telesync", "Line Audio", "Line", "Decent source with some hiss and flat, thin sound.", {
    noiseReduction: 0.35, dereverb: 0.15, dialogue: 0.4, clarity: 0.4, bass: 0.3, width: 0.3, leveling: 0.45, boostDB: 3,
  }),
  preset("quiet", "Too Quiet", "Quiet", "Clean but too quiet, or dialogue buried in music.", {
    noiseReduction: 0.15, dereverb: 0, dialogue: 0.5, clarity: 0.2, bass: 0.15, width: 0.15, leveling: 0.8, boostDB: 9,
  }),
  preset("night", "Night Mode", "Night", "One steady volume. Clear voices, tamed explosions.", {
    noiseReduction: 0.45, dereverb: 0.2, dialogue: 0.8, clarity: 0.3, bass: 0, width: 0.1, leveling: 1, boostDB: 6,
  }),
  preset("max", "Maximum", "Max", "Everything cranked, for the worst recordings.", {
    noiseReduction: 1, dereverb: 0.9, dialogue: 0.9, clarity: 0.8, bass: 0.5, width: 0.6, leveling: 0.9, boostDB: 9,
  }),
]);

export const DEFAULT_SETTINGS = PRESETS[0].settings;

const KNOBS = ["noiseReduction", "dereverb", "dialogue", "clarity", "bass", "width", "leveling"];

export function clampSettings(s) {
  const out = { ...DEFAULT_SETTINGS, ...s };
  out.isEnabled = out.isEnabled !== false;
  for (const key of KNOBS) out[key] = clamp01(out[key]);
  out.boostDB = Number.isFinite(out.boostDB) ? Math.min(Math.max(out.boostDB, BOOST_RANGE[0]), BOOST_RANGE[1]) : 0;
  return out;
}

export function matchingPreset(s) {
  return PRESETS.find((p) => KNOBS.every((k) => p.settings[k] === s[k]) && p.settings.boostDB === s.boostDB) || null;
}

// MARK: - Biquad (RBJ Audio EQ Cookbook, transposed direct form II)

const IDENTITY = Object.freeze({ b0: 1, b1: 0, b2: 0, a1: 0, a2: 0 });
const isIdentity = (c) => c.b0 === 1 && c.b1 === 0 && c.b2 === 0 && c.a1 === 0 && c.a2 === 0;

function intermediates(frequency, q, sampleRate) {
  const clamped = Math.min(Math.max(frequency, 10), sampleRate * 0.45);
  const w0 = (2 * Math.PI * clamped) / sampleRate;
  return [Math.cos(w0), Math.sin(w0) / (2 * q)];
}

const normalized = (b0, b1, b2, a0, a1, a2) => ({ b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0 });

export const Biquad = {
  highPass(frequency, q, sampleRate) {
    const [c, alpha] = intermediates(frequency, q, sampleRate);
    return normalized((1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + alpha, -2 * c, 1 - alpha);
  },
  peaking(frequency, q, gainDB, sampleRate) {
    if (Math.abs(gainDB) <= 0.01) return IDENTITY;
    const a = Math.pow(10, gainDB / 40);
    const [c, alpha] = intermediates(frequency, q, sampleRate);
    return normalized(1 + alpha * a, -2 * c, 1 - alpha * a, 1 + alpha / a, -2 * c, 1 - alpha / a);
  },
  lowShelf(frequency, q, gainDB, sampleRate) {
    if (Math.abs(gainDB) <= 0.01) return IDENTITY;
    const a = Math.pow(10, gainDB / 40);
    const [c, alpha] = intermediates(frequency, q, sampleRate);
    const k = 2 * Math.sqrt(a) * alpha;
    return normalized(
      a * (a + 1 - (a - 1) * c + k), 2 * a * (a - 1 - (a + 1) * c), a * (a + 1 - (a - 1) * c - k),
      a + 1 + (a - 1) * c + k, -2 * (a - 1 + (a + 1) * c), a + 1 + (a - 1) * c - k,
    );
  },
  highShelf(frequency, q, gainDB, sampleRate) {
    if (Math.abs(gainDB) <= 0.01) return IDENTITY;
    const a = Math.pow(10, gainDB / 40);
    const [c, alpha] = intermediates(frequency, q, sampleRate);
    const k = 2 * Math.sqrt(a) * alpha;
    return normalized(
      a * (a + 1 + (a - 1) * c + k), -2 * a * (a - 1 + (a + 1) * c), a * (a + 1 + (a - 1) * c - k),
      a + 1 - (a - 1) * c + k, 2 * (a - 1 - (a + 1) * c), a + 1 - (a - 1) * c - k,
    );
  },
};

class StereoBiquad {
  constructor(coefficients = IDENTITY) {
    this.c = coefficients;
    this.l1 = 0; this.l2 = 0; this.r1 = 0; this.r2 = 0;
  }

  process(left, right, count) {
    const c = this.c;
    if (isIdentity(c)) return;
    let { l1, l2, r1, r2 } = this;
    for (let i = 0; i < count; i++) {
      const xl = left[i];
      const yl = c.b0 * xl + l1;
      l1 = c.b1 * xl - c.a1 * yl + l2;
      l2 = c.b2 * xl - c.a2 * yl;
      left[i] = yl;
      const xr = right[i];
      const yr = c.b0 * xr + r1;
      r1 = c.b1 * xr - c.a1 * yr + r2;
      r2 = c.b2 * xr - c.a2 * yr;
      right[i] = yr;
    }
    const flush = (v) => (Math.abs(v) < 1e-18 ? 0 : v);
    this.l1 = flush(l1); this.l2 = flush(l2); this.r1 = flush(r1); this.r2 = flush(r2);
  }
}

// MARK: - FFT (in-place iterative radix-2, split real/imaginary)

class FFT {
  constructor(size) {
    this.size = size;
    this.cos = new Float32Array(size / 2);
    this.sin = new Float32Array(size / 2);
    for (let k = 0; k < size / 2; k++) {
      const angle = (2 * Math.PI * k) / size;
      this.cos[k] = Math.cos(angle);
      this.sin[k] = Math.sin(angle);
    }
    const bits = Math.log2(size);
    this.reversed = new Uint32Array(size);
    for (let i = 0; i < size; i++) {
      let r = 0;
      for (let b = 0, v = i; b < bits; b++, v >>= 1) r = (r << 1) | (v & 1);
      this.reversed[i] = r;
    }
  }

  forward(re, im) { this.transform(re, im, -1); }

  inverse(re, im) {
    this.transform(re, im, 1);
    const scale = 1 / this.size;
    for (let i = 0; i < this.size; i++) { re[i] *= scale; im[i] *= scale; }
  }

  transform(re, im, direction) {
    const n = this.size;
    for (let i = 0; i < n; i++) {
      const j = this.reversed[i];
      if (j > i) {
        let t = re[i]; re[i] = re[j]; re[j] = t;
        t = im[i]; im[i] = im[j]; im[j] = t;
      }
    }
    for (let length = 2; length <= n; length *= 2) {
      const half = length / 2;
      const step = n / length;
      for (let start = 0; start < n; start += length) {
        for (let k = 0; k < half; k++) {
          const wr = this.cos[k * step];
          const wi = direction * this.sin[k * step];
          const a = start + k;
          const b = a + half;
          const vr = re[b] * wr - im[b] * wi;
          const vi = re[b] * wi + im[b] * wr;
          re[b] = re[a] - vr; im[b] = im[a] - vi;
          re[a] += vr; im[a] += vi;
        }
      }
    }
  }
}

// MARK: - Spectral cleaner (noise + late reverb), see SpectralCleaner.swift

export const BAND_COUNT = 32;

class SpectralCleaner {
  constructor(sampleRate) {
    const n = (this.fftSize = sampleRate > 64000 ? 2048 : 1024);
    const h = (this.hopSize = n / 4);
    const bins = (this.bins = n / 2 + 1);
    this.latency = n;
    this.noiseAmount = 0;
    this.reverbAmount = 0;
    this.reductionDB = 0;
    this.fft = new FFT(n);

    this.window = new Float32Array(n);
    for (let i = 0; i < n; i++) this.window[i] = Math.sqrt(0.5 - 0.5 * Math.cos((2 * Math.PI * i) / n));
    let overlapSum = 0;
    for (let i = 0; i < n; i += h) overlapSum += this.window[i] * this.window[i];
    this.overlapScale = 1 / overlapSum;

    this.inL = new Float32Array(n); this.inR = new Float32Array(n);
    this.outL = new Float32Array(n); this.outR = new Float32Array(n);
    this.readyL = new Float32Array(h); this.readyR = new Float32Array(h);
    this.re = new Float32Array(n); this.im = new Float32Array(n);
    this.position = 0;

    this.power = new Float32Array(bins);
    this.fast = new Float32Array(bins);
    this.slow = new Float32Array(bins);
    this.long = new Float32Array(bins);
    this.clean = new Float32Array(bins);
    this.floorEstimate = new Float32Array(bins);
    this.late = new Float32Array(bins);
    this.raw = new Float32Array(bins).fill(1);
    this.gain = new Float32Array(bins).fill(1);
    this.primed = false;
    this.framesSeen = 0;
    this.warmupFrames = n / h;

    const hopSeconds = h / sampleRate;
    const perFrame = (seconds) => Math.exp(-hopSeconds / seconds);
    this.fastSmoothing = perFrame(0.01);
    this.slowSmoothing = perFrame(0.1);
    this.longSmoothing = perFrame(1.0);
    this.prioriSmoothing = 0.97;
    this.noiseBias = 2.3;
    this.neighbourhoodRadius = 3;
    this.settleFrames = Math.max(1, Math.round(0.25 / hopSeconds));

    this.minimumWindowCount = 10;
    this.minimumWindowFrames = Math.max(1, Math.round(0.5 / hopSeconds));
    this.currentMin = new Float32Array(bins).fill(FLOAT_MAX);
    this.minima = new Float32Array(bins * this.minimumWindowCount).fill(FLOAT_MAX);
    this.framesInMinimumWindow = 0;
    this.minimumWindowIndex = 0;

    this.reverbDelayFrames = Math.max(1, Math.round(0.05 / hopSeconds));
    const decayRate = (3 * Math.log(10)) / 0.8;
    this.reverbDecay = Math.exp(-2 * decayRate * this.reverbDelayFrames * hopSeconds);
    this.history = new Float32Array(bins * this.reverbDelayFrames);
    this.historyIndex = 0;

    this.inputBands = new Float32Array(BAND_COUNT).fill(-120);
    this.outputBands = new Float32Array(BAND_COUNT).fill(-120);
    this.bandEdges = new Int32Array(BAND_COUNT + 1);
    const binWidth = sampleRate / n;
    const high = Math.min(16000, sampleRate * 0.45);
    let previous = 0;
    for (let b = 0; b <= BAND_COUNT; b++) {
      const frequency = 50 * Math.pow(high / 50, b / BAND_COUNT);
      const edge = Math.min(Math.max(Math.round(frequency / binWidth), previous + 1), bins - 1);
      this.bandEdges[b] = edge;
      previous = edge;
    }
    this.bandScale = 1 / (0.1 * n * n);
  }

  process(left, right, count) {
    const writeBase = this.fftSize - this.hopSize;
    for (let i = 0; i < count; i++) {
      this.inL[writeBase + this.position] = left[i];
      this.inR[writeBase + this.position] = right[i];
      left[i] = this.readyL[this.position];
      right[i] = this.readyR[this.position];
      if (++this.position === this.hopSize) {
        this.processFrame();
        this.position = 0;
      }
    }
  }

  processFrame() {
    const { fftSize: n, hopSize: h, re, im, window: w, inL, inR, outL, outR } = this;
    for (let i = 0; i < n; i++) { re[i] = inL[i] * w[i]; im[i] = inR[i] * w[i]; }
    inL.copyWithin(0, h); inR.copyWithin(0, h);

    this.fft.forward(re, im);
    const active = this.computeGains();
    this.updateBands();
    if (active) {
      const g = this.gain;
      for (let k = 0; k < this.bins; k++) {
        const mirror = (n - k) & (n - 1);
        re[k] *= g[k]; im[k] *= g[k];
        if (mirror !== k) { re[mirror] *= g[k]; im[mirror] *= g[k]; }
      }
    }
    this.fft.inverse(re, im);

    for (let i = 0; i < n; i++) {
      const ws = w[i] * this.overlapScale;
      outL[i] += re[i] * ws;
      outR[i] += im[i] * ws;
    }
    this.readyL.set(outL.subarray(0, h));
    this.readyR.set(outR.subarray(0, h));
    outL.copyWithin(0, h); outR.copyWithin(0, h);
    outL.fill(0, n - h); outR.fill(0, n - h);
  }

  updateBands() {
    const { power, gain: g, bandEdges, bandScale } = this;
    for (let b = 0; b < BAND_COUNT; b++) {
      let before = 0, after = 0;
      for (let k = bandEdges[b]; k < bandEdges[b + 1]; k++) {
        before += power[k];
        after += power[k] * g[k] * g[k];
      }
      this.inputBands[b] = 10 * Math.log10(before * bandScale + 1e-12);
      this.outputBands[b] = 10 * Math.log10(after * bandScale + 1e-12);
    }
  }

  computeGains() {
    const { fftSize: n, bins, re, im, power, fast, slow, long, currentMin, minima, floorEstimate, history, late, clean, raw, gain: g } = this;

    for (let k = 0; k < bins; k++) {
      const m = (n - k) & (n - 1);
      power[k] = 0.25 * (re[k] * re[k] + im[k] * im[k] + re[m] * re[m] + im[m] * im[m]) + 1e-20;
    }

    const settling = this.framesSeen < this.warmupFrames + this.settleFrames;
    if (settling) this.framesSeen++;
    if (this.framesSeen <= this.warmupFrames) {
      g.fill(1); clean.set(power); this.reductionDB = 0;
      return false;
    }

    const longCoefficient = settling ? this.slowSmoothing : this.longSmoothing;
    const historyBase = this.historyIndex * bins;
    for (let k = 0; k < bins; k++) {
      const p = power[k];
      if (this.primed) {
        fast[k] = fast[k] * this.fastSmoothing + p * (1 - this.fastSmoothing);
        slow[k] = slow[k] * this.slowSmoothing + p * (1 - this.slowSmoothing);
        long[k] = long[k] * longCoefficient + p * (1 - longCoefficient);
      } else {
        fast[k] = p; slow[k] = p; long[k] = p;
      }
      if (!settling) currentMin[k] = Math.min(currentMin[k], slow[k]);
      let lowest = currentMin[k];
      for (let slot = 0; slot < this.minimumWindowCount; slot++) lowest = Math.min(lowest, minima[slot * bins + k]);
      floorEstimate[k] = lowest;
      late[k] = history[historyBase + k] * this.reverbDecay;
      history[historyBase + k] = fast[k];
    }
    this.primed = true;
    this.historyIndex = (this.historyIndex + 1) % this.reverbDelayFrames;

    if (!settling) this.framesInMinimumWindow++;
    if (this.framesInMinimumWindow >= this.minimumWindowFrames) {
      minima.set(currentMin, this.minimumWindowIndex * bins);
      currentMin.fill(FLOAT_MAX);
      this.minimumWindowIndex = (this.minimumWindowIndex + 1) % this.minimumWindowCount;
      this.framesInMinimumWindow = 0;
    }

    const noise = clamp01(this.noiseAmount);
    const reverb = clamp01(this.reverbAmount);
    const noiseWeight = noise > 0 ? 1 + noise : 0;
    const reverbWeight = 1.6 * reverb;
    if (noiseWeight <= 0 && reverbWeight <= 0) {
      g.fill(1); clean.set(power); this.reductionDB = 0;
      return false;
    }

    const radius = this.neighbourhoodRadius;
    for (let k = 0; k < bins; k++) {
      const p = power[k];
      let neighbourhood = floorEstimate[k];
      for (let j = Math.max(k - radius, 0), end = Math.min(k + radius, bins - 1); j <= end; j++) {
        neighbourhood = Math.min(neighbourhood, floorEstimate[j]);
      }
      const steadiness = floorEstimate[k] / Math.max(long[k], 1e-20);
      const noiseLikeness = Math.min(Math.max((0.92 - steadiness) / 0.15, 0), 1);
      const hasEstimate = neighbourhood < FLOAT_MAX;
      const noiseEstimate = hasEstimate ? noiseWeight * noiseLikeness * this.noiseBias * neighbourhood : 0;

      let noiseGain = 1;
      if (noiseEstimate > 1e-20) {
        const posteriori = p / noiseEstimate;
        const priori = (this.prioriSmoothing * clean[k]) / noiseEstimate + (1 - this.prioriSmoothing) * Math.max(posteriori - 1, 0);
        noiseGain = priori / (1 + priori);
      }
      clean[k] = noiseGain * noiseGain * p;

      let echoGain = 1;
      if (reverbWeight > 0) echoGain = Math.sqrt(Math.max(1 - (reverbWeight * late[k]) / fast[k], 0));
      raw[k] = noiseGain * echoGain;
    }

    const floor = decibelsToGain(-(6 + 14 * Math.max(noise, reverb)));
    let total = 0, kept = 0;
    for (let k = 0; k < bins; k++) {
      const value = Math.max(0.25 * raw[Math.max(k - 1, 0)] + 0.5 * raw[k] + 0.25 * raw[Math.min(k + 1, bins - 1)], floor);
      g[k] = value;
      total += power[k];
      kept += value * value * power[k];
    }
    this.reductionDB = total > 1e-12 ? 10 * Math.log10(kept / total) : 0;
    return true;
  }
}

// MARK: - Exciter and mid/side stage, see Exciter.swift

class Exciter {
  constructor(sampleRate, maximumBlockSize) {
    this.amount = 0;
    this.band = new StereoBiquad(Biquad.highPass(3000, 0.707, sampleRate));
    this.harmonics = new StereoBiquad(Biquad.highPass(5500, 0.707, sampleRate));
    this.sl = new Float32Array(maximumBlockSize);
    this.sr = new Float32Array(maximumBlockSize);
    this.envL = 0; this.envR = 0;
    this.attack = smoothingCoefficient(0.0005, sampleRate);
    this.release = smoothingCoefficient(0.03, sampleRate);
  }

  process(left, right, count) {
    if (this.amount <= 0) return;
    const { sl, sr } = this;
    sl.set(left.subarray(0, count)); sr.set(right.subarray(0, count));
    this.band.process(sl, sr, count);
    const attack = this.attack, release = this.release;
    let envL = this.envL, envR = this.envR;
    for (let i = 0; i < count; i++) {
      // Envelope-normalized saturation: tanh adds odd harmonics, the squared term even
      // ones (its DC is filtered out by the second high-pass).
      const xl = sl[i], ml = Math.abs(xl);
      envL = ml + (envL - ml) * (ml > envL ? attack : release);
      const el = envL + 1e-6, ul = xl / el;
      sl[i] = el * (Math.tanh(2.5 * ul) + 0.2 * ul * ul);
      const xr = sr[i], mr = Math.abs(xr);
      envR = mr + (envR - mr) * (mr > envR ? attack : release);
      const er = envR + 1e-6, ur = xr / er;
      sr[i] = er * (Math.tanh(2.5 * ur) + 0.2 * ur * ur);
    }
    this.harmonics.process(sl, sr, count);
    const mix = 0.4 * this.amount;
    for (let i = 0; i < count; i++) { left[i] += mix * sl[i]; right[i] += mix * sr[i]; }
    this.envL = envL < 1e-9 ? 0 : envL;
    this.envR = envR < 1e-9 ? 0 : envR;
  }
}

class StereoStage {
  constructor(sampleRate) {
    this.width = 0;
    this.dialogue = 0;
    this.delay = new Float32Array(Math.max(1, Math.floor(0.013 * sampleRate)));
    this.delayIndex = 0;
    this.c = Biquad.highPass(300, 0.707, sampleRate);
    this.z1 = 0; this.z2 = 0;
  }

  process(left, right, count) {
    const sideGain = (1 + 0.6 * this.width) * (1 - 0.35 * this.dialogue);
    const pseudo = 0.3 * this.width;
    if (sideGain === 1 && pseudo <= 0) return;
    const { delay: d, c } = this;
    let { z1, z2, delayIndex } = this;
    for (let i = 0; i < count; i++) {
      const mid = 0.5 * (left[i] + right[i]);
      let side = 0.5 * (left[i] - right[i]) * sideGain;
      if (pseudo > 0) {
        const y = c.b0 * mid + z1;
        z1 = c.b1 * mid - c.a1 * y + z2;
        z2 = c.b2 * mid - c.a2 * y;
        side += pseudo * d[delayIndex];
        d[delayIndex] = y;
        if (++delayIndex === d.length) delayIndex = 0;
      }
      left[i] = mid + side;
      right[i] = mid - side;
    }
    this.z1 = Math.abs(z1) < 1e-18 ? 0 : z1;
    this.z2 = Math.abs(z2) < 1e-18 ? 0 : z2;
    this.delayIndex = delayIndex;
  }
}

// MARK: - Leveler and limiter, see Dynamics.swift

class Leveler {
  constructor(sampleRate) {
    this.detector = smoothingCoefficient(0.03, sampleRate);
    this.attack = smoothingCoefficient(0.015, sampleRate);
    this.release = smoothingCoefficient(0.35, sampleRate);
    this.programRise = smoothingCoefficient(0.4, sampleRate);
    this.programFall = smoothingCoefficient(6, sampleRate);
    this.envelope = 0;
    this.smoothedGainDB = 0;
    this.programDB = -30;
    this.knee = 10;
    this.gateRange = 18;
    this.expansion = 2;
    this.lowestGate = -65;
    this.gainDB = 0;
    this._amount = 0;
    this.configure();
  }

  get amount() { return this._amount; }

  set amount(value) {
    if (value !== this._amount) { this._amount = value; this.configure(); }
  }

  configure() {
    const a = clamp01(this._amount);
    this.threshold = -20 - 18 * a;
    this.slope = 1 / (1 + 4 * a) - 1;
    this.makeup = a > 0 ? -0.9 * this.compressionDB(-16) : 0;
  }

  compressionDB(levelDB) {
    const over = levelDB - this.threshold;
    if (over <= -this.knee / 2) return 0;
    if (over < this.knee / 2) {
      const x = over + this.knee / 2;
      return (this.slope * x * x) / (2 * this.knee);
    }
    return this.slope * over;
  }

  process(left, right, count) {
    if (!(this._amount > 0 || Math.abs(this.smoothedGainDB) > 0.01)) { this.gainDB = 0; return; }
    const enabled = this._amount > 0;
    let env = this.envelope, current = this.smoothedGainDB, program = this.programDB;
    for (let i = 0; i < count; i++) {
      const l = left[i], r = right[i];
      env = Math.max(env * this.detector + 0.5 * (l * l + r * r) * (1 - this.detector), 1e-12);
      const levelDB = 10 * Math.log10(env);
      program = levelDB + (program - levelDB) * (levelDB > program ? this.programRise : this.programFall);
      const gate = Math.max(program - this.gateRange, this.lowestGate);
      let target = 0;
      if (enabled) {
        target = this.compressionDB(levelDB) + this.makeup;
        if (levelDB < gate) target += Math.max(this.expansion * (levelDB - gate), -this.makeup);
      }
      current = target + (current - target) * (target < current ? this.attack : this.release);
      const gain = Math.pow(10, current / 20);
      left[i] *= gain;
      right[i] *= gain;
    }
    this.envelope = env;
    this.programDB = program;
    this.smoothedGainDB = current;
    this.gainDB = current;
  }
}

class Limiter {
  constructor(sampleRate) {
    const L = (this.lookahead = Math.max(1, Math.round(0.0015 * sampleRate)));
    this.ceiling = decibelsToGain(-1);
    this.reductionDB = 0;
    this.delayL = new Float32Array(L);
    this.delayR = new Float32Array(L);
    this.requests = new Float32Array(L + 1).fill(1);
    this.box = new Float32Array(L).fill(1);
    this.boxSum = L;
    this.delayIndex = 0;
    this.requestIndex = 0;
    this.releaseGain = 1;
    this.releaseCoefficient = smoothingCoefficient(0.08, sampleRate);
  }

  process(left, right, count) {
    const { delayL, delayR, requests: req, box, lookahead: L, ceiling } = this;
    const holdLength = L + 1;
    let minimumGain = 1;
    for (let i = 0; i < count; i++) {
      const l = left[i], r = right[i];
      const peak = Math.max(Math.abs(l), Math.abs(r));
      req[this.requestIndex] = peak > ceiling ? ceiling / peak : 1;
      if (++this.requestIndex === holdLength) this.requestIndex = 0;

      let held = 1;
      for (let j = 0; j < holdLength; j++) if (req[j] < held) held = req[j];
      this.releaseGain = held < this.releaseGain ? held : held + (this.releaseGain - held) * this.releaseCoefficient;

      this.boxSum += this.releaseGain - box[this.delayIndex];
      box[this.delayIndex] = this.releaseGain;
      const gain = this.boxSum / L;

      const dl = delayL[this.delayIndex], dr = delayR[this.delayIndex];
      delayL[this.delayIndex] = l;
      delayR[this.delayIndex] = r;
      if (++this.delayIndex === L) this.delayIndex = 0;

      left[i] = Math.min(Math.max(dl * gain, -ceiling), ceiling);
      right[i] = Math.min(Math.max(dr * gain, -ceiling), ceiling);
      if (gain < minimumGain) minimumGain = gain;
    }
    this.reductionDB = gainToDecibels(minimumGain);
  }
}

// MARK: - Enhancer, see Enhancer.swift

export class Enhancer {
  static maximumBlockSize = 4096;

  constructor(sampleRate, settings = DEFAULT_SETTINGS) {
    this.sampleRate = sampleRate;
    this.rumble = new StereoBiquad();
    this.cleaner = new SpectralCleaner(sampleRate);
    this.bassShelf = new StereoBiquad();
    this.mudCut = new StereoBiquad();
    this.presence = new StereoBiquad();
    this.airShelf = new StereoBiquad();
    this.exciter = new Exciter(sampleRate, Enhancer.maximumBlockSize);
    this.stereo = new StereoStage(sampleRate);
    this.leveler = new Leveler(sampleRate);
    this.limiter = new Limiter(sampleRate);
    this.latency = this.cleaner.latency + this.limiter.lookahead;

    this.dryDelayL = new Float32Array(this.latency);
    this.dryDelayR = new Float32Array(this.latency);
    this.dryIndex = 0;
    this.dryL = new Float32Array(Enhancer.maximumBlockSize);
    this.dryR = new Float32Array(Enhancer.maximumBlockSize);
    this.mixStep = 1 / (0.04 * sampleRate);
    this.gainSmoothing = smoothingCoefficient(0.03, sampleRate);
    this.outputGain = 1;
    this.outputGainTarget = 1;
    this.inputPeak = 0;
    this.outputPeak = 0;

    const initial = clampSettings(settings);
    this.wetMix = initial.isEnabled ? 1 : 0;
    this.update(initial);
    this.outputGain = this.outputGainTarget;
  }

  update(settings) {
    const s = (this.settings = clampSettings(settings));
    const rate = this.sampleRate;
    this.rumble.c = s.noiseReduction > 0 || s.bass > 0 ? Biquad.highPass(35, 0.707, rate) : IDENTITY;
    this.cleaner.noiseAmount = s.noiseReduction;
    this.cleaner.reverbAmount = s.dereverb;
    this.bassShelf.c = Biquad.lowShelf(110, 0.7, 7 * s.bass, rate);
    this.mudCut.c = Biquad.peaking(300, 1.0, -5 * s.dialogue, rate);
    this.presence.c = Biquad.peaking(2800, 0.9, 6 * s.dialogue, rate);
    this.airShelf.c = Biquad.highShelf(8000, 0.7, 3 * s.clarity, rate);
    this.exciter.amount = s.clarity;
    this.stereo.width = s.width;
    this.stereo.dialogue = s.dialogue;
    this.leveler.amount = s.leveling;
    this.outputGainTarget = decibelsToGain(s.boostDB);
  }

  /** Processes Float32Arrays in place. Any length is fine. */
  process(left, right, frameCount = left.length) {
    for (let offset = 0; offset < frameCount; offset += Enhancer.maximumBlockSize) {
      const count = Math.min(Enhancer.maximumBlockSize, frameCount - offset);
      this.processBlock(left.subarray(offset, offset + count), right.subarray(offset, offset + count), count);
    }
  }

  /** Meter snapshot; peaks cover everything since the previous call. */
  readMeters() {
    const meters = {
      inputPeak: this.inputPeak,
      outputPeak: this.outputPeak,
      cleanupDB: this.cleaner.reductionDB,
      levelerDB: this.leveler.gainDB,
      limiterDB: this.limiter.reductionDB,
      spectrum: { input: Array.from(this.cleaner.inputBands), output: Array.from(this.cleaner.outputBands) },
    };
    this.inputPeak = 0;
    this.outputPeak = 0;
    return meters;
  }

  processBlock(left, right, count) {
    const { dryL, dryR, dryDelayL, dryDelayR } = this;
    let inputPeak = this.inputPeak;
    for (let i = 0; i < count; i++) {
      const l = left[i], r = right[i];
      inputPeak = Math.max(inputPeak, Math.abs(l), Math.abs(r));
      dryL[i] = dryDelayL[this.dryIndex];
      dryR[i] = dryDelayR[this.dryIndex];
      dryDelayL[this.dryIndex] = l;
      dryDelayR[this.dryIndex] = r;
      if (++this.dryIndex === this.latency) this.dryIndex = 0;
    }
    this.inputPeak = inputPeak;

    this.rumble.process(left, right, count);
    this.cleaner.process(left, right, count);
    this.bassShelf.process(left, right, count);
    this.mudCut.process(left, right, count);
    this.presence.process(left, right, count);
    this.airShelf.process(left, right, count);
    this.exciter.process(left, right, count);
    this.stereo.process(left, right, count);
    this.leveler.process(left, right, count);

    const target = this.outputGainTarget;
    let gain = this.outputGain;
    if (gain !== target) {
      for (let i = 0; i < count; i++) {
        gain = target + (gain - target) * this.gainSmoothing;
        left[i] *= gain;
        right[i] *= gain;
      }
      if (Math.abs(gain - target) < 1e-5) gain = target;
      this.outputGain = gain;
    } else if (gain !== 1) {
      for (let i = 0; i < count; i++) { left[i] *= gain; right[i] *= gain; }
    }

    this.limiter.process(left, right, count);

    const mixTarget = this.settings.isEnabled ? 1 : 0;
    if (this.wetMix !== mixTarget || mixTarget === 0) {
      let mix = this.wetMix;
      for (let i = 0; i < count; i++) {
        mix = mix < mixTarget ? Math.min(mix + this.mixStep, mixTarget) : Math.max(mix - this.mixStep, mixTarget);
        left[i] = dryL[i] + (left[i] - dryL[i]) * mix;
        right[i] = dryR[i] + (right[i] - dryR[i]) * mix;
      }
      this.wetMix = mix;
    }

    let outputPeak = this.outputPeak;
    for (let i = 0; i < count; i++) {
      if (!Number.isFinite(left[i])) left[i] = 0;
      if (!Number.isFinite(right[i])) right[i] = 0;
      outputPeak = Math.max(outputPeak, Math.abs(left[i]), Math.abs(right[i]));
    }
    this.outputPeak = outputPeak;
  }
}
