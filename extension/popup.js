import { BOOST_RANGE, DEFAULT_SETTINGS, PRESETS, clampSettings, matchingPreset } from "./dsp.js";

const $ = (id) => document.getElementById(id);

const ICONS = {
  cam: '<rect width="18" height="18" x="3" y="3" rx="2"/><path d="M7 3v18"/><path d="M3 7.5h4"/><path d="M3 12h18"/><path d="M3 16.5h4"/><path d="M17 3v18"/><path d="M17 7.5h4"/><path d="M17 16.5h4"/>',
  telesync: '<path d="M2 13a2 2 0 0 0 2-2V7a2 2 0 0 1 4 0v13a2 2 0 0 0 4 0V4a2 2 0 0 1 4 0v13a2 2 0 0 0 4 0v-4a2 2 0 0 1 2-2"/>',
  quiet: '<path d="M11 4.702a.705.705 0 0 0-1.203-.498L6.413 7.587A1.4 1.4 0 0 1 5.416 8H3a1 1 0 0 0-1 1v6a1 1 0 0 0 1 1h2.416a1.4 1.4 0 0 1 .997.413l3.383 3.384A.705.705 0 0 0 11 19.298z"/><path d="M16 9a5 5 0 0 1 0 6"/>',
  night: '<path d="M12 3a6 6 0 0 0 9 9 9 9 0 1 1-9-9"/><path d="M20 3v4"/><path d="M22 5h-4"/>',
  max: '<path d="M4 14a1 1 0 0 1-.78-1.63l9.9-10.2a.5.5 0 0 1 .86.46l-1.92 6.02A1 1 0 0 0 13 10h7a1 1 0 0 1 .78 1.63l-9.9 10.2a.5.5 0 0 1-.86-.46l1.92-6.02A1 1 0 0 0 11 14z"/>',
};

const KNOBS = [
  ["noiseReduction", "Noise", "Hiss, hum, air conditioning, crowd murmur."],
  ["dereverb", "Echo", "The big-room echo of a recording made in a theater."],
  ["dialogue", "Dialogue", "Cuts boom and mud, brings voices forward."],
  ["clarity", "Clarity", "Restores the crisp top end cheap mics lose."],
  ["bass", "Bass", "Adds back low end."],
  ["width", "Width", "Spreads the sound out. Turns mono into stereo."],
  ["leveling", "Leveling", "Quiet lines louder, explosions softer."],
  ["boostDB", "Boost", "Extra volume. A limiter keeps it from distorting."],
];

const BANDS = 32;
const state = {
  tabId: null,
  activeTabId: null,
  settings: { ...DEFAULT_SETTINGS },
  busy: false,
  spectrum: { input: new Array(BANDS).fill(-120), output: new Array(BANDS).fill(-120) },
};

const send = (type, extra = {}) => chrome.runtime.sendMessage({ target: "background", type, ...extra });
const runningHere = () => state.activeTabId !== null && state.activeTabId === state.tabId;

// MARK: - Rendering

function renderStatus() {
  const here = runningHere();
  const power = $("power");
  power.setAttribute("aria-pressed", String(here));
  power.title = here ? "Turn Unmuffle off for this tab" : "Turn Unmuffle on for this tab";
  power.disabled = state.busy;
  $("status").textContent = here
    ? state.settings.isEnabled ? "Enhancing this tab" : "Playing the original"
    : state.activeTabId !== null ? "On in another tab" : "Off";
  $("hint").hidden = here;
  $("cleanup").hidden = !here;
  $("legend-original").hidden = !here;
  $("legend-enhanced").hidden = !here || !state.settings.isEnabled;
}

function showError(title, message) {
  $("banner").hidden = !title;
  $("banner-title").textContent = title || "";
  $("banner-message").textContent = message || "";
}

function renderSettings() {
  const s = state.settings;
  for (const button of document.querySelectorAll(".switch button")) {
    button.setAttribute("aria-checked", String(String(s.isEnabled) === button.dataset.enhanced));
  }
  const active = matchingPreset(s);
  for (const tile of document.querySelectorAll(".tile")) {
    tile.setAttribute("aria-pressed", String(active?.id === tile.dataset.id));
  }
  $("summary").textContent = active ? active.summary : "Your own mix. Pick a preset to start over.";
  $("custom").hidden = active !== null;
  for (const [key] of KNOBS) {
    const input = $(`knob-${key}`);
    input.value = s[key];
    updateKnobLabel(key);
  }
  renderStatus();
}

function updateKnobLabel(key) {
  const input = $(`knob-${key}`);
  const value = Number(input.value);
  const fraction = (value - Number(input.min)) / (Number(input.max) - Number(input.min));
  input.style.setProperty("--fill", `${fraction * 100}%`);
  $(`value-${key}`).textContent = key === "boostDB" ? `+${Math.round(value)} dB` : `${Math.round(value * 100)}%`;
}

function drawSpectrum() {
  const canvas = $("spectrum");
  const ratio = window.devicePixelRatio || 1;
  const width = 288, height = 70;
  if (canvas.width !== width * ratio) {
    canvas.width = width * ratio;
    canvas.height = height * ratio;
  }
  const ctx = canvas.getContext("2d");
  ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
  ctx.clearRect(0, 0, width, height);

  const styles = getComputedStyle(document.documentElement);
  const ghost = styles.getPropertyValue("--ghost").trim();
  const accent = styles.getPropertyValue("--accent").trim();

  const gap = 3;
  const barWidth = (width - gap * (BANDS - 1)) / BANDS;
  const barHeight = (db) => Math.max(3, Math.min(Math.max((db + 90) / 80, 0), 1) * height);
  const bar = (i, h, fill) => {
    ctx.fillStyle = fill;
    ctx.beginPath();
    ctx.roundRect(i * (barWidth + gap), height - h, barWidth, h, Math.min(barWidth / 2, 3));
    ctx.fill();
  };
  const here = runningHere();
  for (let i = 0; i < BANDS; i++) {
    if (!here) {
      bar(i, 3, ghost);
      continue;
    }
    bar(i, barHeight(state.spectrum.input[i]), ghost);
    if (state.settings.isEnabled) bar(i, barHeight(state.spectrum.output[i]), accent);
  }

  // Average gap between the bars, the same number the Mac app shows.
  let removed = 0;
  for (let i = 0; i < BANDS; i++) removed += Math.max(state.spectrum.input[i] - state.spectrum.output[i], 0);
  removed /= BANDS;
  $("cleanup").textContent = !state.settings.isEnabled ? "Bypassed" : removed >= 0.5 ? `−${Math.round(removed)} dB noise & echo` : "Listening…";
}

// MARK: - Settings

let saveTimer = null;
function changeSettings(next) {
  state.settings = clampSettings(next);
  renderSettings();
  drawSpectrum();
  send("settings", { settings: state.settings });
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => chrome.storage.local.set({ settings: state.settings }), 200);
}

function buildControls() {
  $("tiles").innerHTML = PRESETS.map((p) => `
    <button class="tile" data-id="${p.id}" title="${p.name}" aria-pressed="false">
      <svg viewBox="0 0 24 24" width="16" height="16">${ICONS[p.id]}</svg>${p.shortName}
    </button>`).join("");
  for (const tile of document.querySelectorAll(".tile")) {
    tile.addEventListener("click", () => {
      const preset = PRESETS.find((p) => p.id === tile.dataset.id);
      changeSettings({ ...preset.settings, isEnabled: state.settings.isEnabled });
    });
  }

  $("sliders").innerHTML = KNOBS.map(([key, name, help]) => {
    const [min, max, step] = key === "boostDB" ? [BOOST_RANGE[0], BOOST_RANGE[1], 0.5] : [0, 1, 0.01];
    return `<div class="row" title="${help}">
      <label for="knob-${key}">${name}</label>
      <input id="knob-${key}" type="range" min="${min}" max="${max}" step="${step}">
      <output id="value-${key}"></output>
    </div>`;
  }).join("");
  for (const [key] of KNOBS) {
    $(`knob-${key}`).addEventListener("input", (event) => {
      changeSettings({ ...state.settings, [key]: Number(event.target.value) });
    });
  }

  for (const button of document.querySelectorAll(".switch button")) {
    button.addEventListener("click", () => changeSettings({ ...state.settings, isEnabled: button.dataset.enhanced === "true" }));
  }

  const expanded = localStorage.getItem("fineTuneExpanded") === "true";
  setExpanded(expanded);
  $("tune-toggle").addEventListener("click", () => setExpanded($("sliders").hidden));
}

function setExpanded(expanded) {
  $("sliders").hidden = !expanded;
  $("tune-toggle").setAttribute("aria-expanded", String(expanded));
  try { localStorage.setItem("fineTuneExpanded", String(expanded)); } catch {}
}

// MARK: - On / off

async function toggle() {
  if (state.busy || state.tabId === null) return;
  state.busy = true;
  showError(null);
  renderStatus();
  try {
    if (runningHere()) {
      await send("stop");
      state.activeTabId = null;
    } else {
      const streamId = await chrome.tabCapture.getMediaStreamId({ targetTabId: state.tabId });
      const result = await send("start", { tabId: state.tabId, streamId });
      if (!result?.ok) throw new Error(result?.error || "Unknown error");
      state.activeTabId = state.tabId;
      connectMeters();
    }
  } catch (error) {
    const message = String(error?.message || error);
    if (/chrome:\/\/|Chrome pages|cannot be captured|not allowed/i.test(message)) {
      showError("Can't enhance this page", "Chrome doesn't allow capturing its own pages or the Web Store. Try it on a video tab.");
    } else {
      showError("Couldn't start", message);
    }
  } finally {
    state.busy = false;
    renderStatus();
    drawSpectrum();
  }
}

// MARK: - Live spectrum

let meters = null;
function connectMeters() {
  if (meters || !runningHere()) return;
  meters = chrome.runtime.connect({ name: "meters" });
  meters.onMessage.addListener((data) => {
    // Bars jump up instantly and fall back smoothly.
    for (let i = 0; i < BANDS; i++) {
      state.spectrum.input[i] = Math.max(data.spectrum.input[i], state.spectrum.input[i] - 1.8);
      state.spectrum.output[i] = Math.max(data.spectrum.output[i], state.spectrum.output[i] - 1.8);
    }
  });
  meters.onDisconnect.addListener(() => { meters = null; });
}

function animate() {
  drawSpectrum();
  requestAnimationFrame(animate);
}

// MARK: - Start

async function init() {
  buildControls();
  $("power").addEventListener("click", toggle);
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  state.tabId = tab?.id ?? null;
  const saved = await send("state");
  state.activeTabId = saved?.activeTabId ?? null;
  if (saved?.settings) state.settings = clampSettings(saved.settings);
  renderSettings();
  connectMeters();
  animate();
}

init();
