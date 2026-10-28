import { BOOST_RANGE, DEFAULT_SETTINGS, PRESETS, clampSettings, matchingPreset } from "./dsp.js";
import { drawAnalyzer, removedDB } from "./analyzer.js";

const $ = (id) => document.getElementById(id);
const BANDS = 32;
const CONTROLS = [
  ["noiseReduction", "Noise", "Hiss, hum, air conditioning, crowd murmur."],
  ["dereverb", "Echo", "The big-room echo of a recording made in a theater."],
  ["dialogue", "Dialogue", "Cuts boom and mud, brings voices forward."],
  ["clarity", "Clarity", "Restores the crisp top end cheap mics lose."],
  ["bass", "Bass", "Adds back low end."],
  ["width", "Width", "Spreads the sound out. Turns mono into stereo."],
  ["leveling", "Leveling", "Quiet lines louder, explosions softer."],
  ["boostDB", "Boost", "Extra volume. A limiter keeps it from distorting."],
];

const state = {
  tabId: null,
  activeTabId: null,
  settings: { ...DEFAULT_SETTINGS },
  busy: false,
  spectrum: { input: new Array(BANDS).fill(-120), output: new Array(BANDS).fill(-120) },
};

const send = (type, extra = {}) => chrome.runtime.sendMessage({ target: "background", type, ...extra });
const runningHere = () => state.activeTabId !== null && state.activeTabId === state.tabId;
const accent = () => getComputedStyle(document.documentElement).getPropertyValue("--accent").trim();

// MARK: - Rendering

function render() {
  const s = state.settings;
  const here = runningHere();
  const power = $("power");
  power.checked = here;
  power.disabled = state.busy;
  $("status").textContent = here
    ? s.isEnabled ? "On for this tab" : "On · playing the original"
    : state.activeTabId !== null ? "On in another tab" : "Off";
  $("legend-clean").hidden = !here || !s.isEnabled;

  const active = matchingPreset(s);
  const select = $("preset");
  select.innerHTML = PRESETS.map((p) => `<option value="${p.id}">${p.name}</option>`).join("")
    + (active ? "" : '<option value="custom" disabled>Custom</option>');
  select.value = active ? active.id : "custom";
  $("summary").textContent = active ? active.summary : "Your own settings.";
  for (const button of document.querySelectorAll(".segmented button")) {
    button.setAttribute("aria-checked", String(String(s.isEnabled) === button.dataset.enhanced));
  }
  for (const [key] of CONTROLS) {
    $(`knob-${key}`).value = s[key];
    $(`value-${key}`).textContent = key === "boostDB" ? `+${Math.round(s[key])} dB` : `${Math.round(s[key] * 100)}%`;
  }
}

function showNotice(title, message) {
  $("notice").hidden = !title;
  $("notice").innerHTML = title ? `<b></b><span></span>` : "";
  if (title) {
    $("notice").querySelector("b").textContent = title;
    $("notice").querySelector("span").textContent = message;
  }
}

function frame() {
  const here = runningHere();
  drawAnalyzer($("analyzer"), {
    input: state.spectrum.input, output: state.spectrum.output,
    active: here, enhanced: state.settings.isEnabled, accent: accent(),
  });
  const removed = removedDB(state.spectrum.input, state.spectrum.output);
  $("cleanup").textContent = !here ? "Off" : !state.settings.isEnabled ? "Bypassed" : removed >= 0.5 ? `−${Math.round(removed)} dB` : "—";
  requestAnimationFrame(frame);
}

// MARK: - Settings

let saveTimer = null;
function changeSettings(next) {
  state.settings = clampSettings(next);
  render();
  send("settings", { settings: state.settings });
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => chrome.storage.local.set({ settings: state.settings }), 200);
}

function buildControls() {
  $("sliders").innerHTML = CONTROLS.map(([key, name, help]) => {
    const [min, max, step] = key === "boostDB" ? [BOOST_RANGE[0], BOOST_RANGE[1], 0.5] : [0, 1, 0.01];
    return `<div class="slider" title="${help}">
      <label for="knob-${key}">${name}</label>
      <input id="knob-${key}" type="range" min="${min}" max="${max}" step="${step}">
      <output id="value-${key}"></output>
    </div>`;
  }).join("");
  for (const [key] of CONTROLS) {
    $(`knob-${key}`).addEventListener("input", (event) => changeSettings({ ...state.settings, [key]: Number(event.target.value) }));
  }
  $("preset").addEventListener("change", (event) => {
    const preset = PRESETS.find((p) => p.id === event.target.value);
    if (preset) changeSettings({ ...preset.settings, isEnabled: state.settings.isEnabled });
  });
  for (const button of document.querySelectorAll(".segmented button")) {
    button.addEventListener("click", () => changeSettings({ ...state.settings, isEnabled: button.dataset.enhanced === "true" }));
  }
  const adjust = $("adjust");
  try { adjust.open = localStorage.getItem("adjustOpen") === "true"; } catch {}
  adjust.addEventListener("toggle", () => { try { localStorage.setItem("adjustOpen", String(adjust.open)); } catch {} });
  $("power").addEventListener("change", toggle);
}

// MARK: - On / off

async function toggle() {
  if (state.busy || state.tabId === null) return;
  state.busy = true;
  showNotice(null);
  render();
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
      showNotice("Can't run on this page.", " Chrome doesn't allow capturing its own pages or the Web Store. Try it on a video tab.");
    } else {
      showNotice("Couldn't start.", ` ${message}`);
    }
  } finally {
    state.busy = false;
    render();
  }
}

// MARK: - Live spectrum

let meters = null;
function connectMeters() {
  if (meters || !runningHere()) return;
  meters = chrome.runtime.connect({ name: "meters" });
  meters.onMessage.addListener((data) => {
    for (let i = 0; i < BANDS; i++) {
      state.spectrum.input[i] = Math.max(data.spectrum.input[i], state.spectrum.input[i] - 1.8);
      state.spectrum.output[i] = Math.max(data.spectrum.output[i], state.spectrum.output[i] - 1.8);
    }
  });
  meters.onDisconnect.addListener(() => { meters = null; });
}

// MARK: - Start

async function init() {
  buildControls();
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  state.tabId = tab?.id ?? null;
  const saved = await send("state");
  state.activeTabId = saved?.activeTabId ?? null;
  if (saved?.settings) state.settings = clampSettings(saved.settings);
  render();
  connectMeters();
  frame();
}

init();
