import { BOOST_RANGE, DEFAULT_SETTINGS, PRESETS, clampSettings, matchingPreset } from "./dsp.js";
import { drawAnalyzer, removedDB } from "./analyzer.js";

const $ = (id) => document.getElementById(id);
const BANDS = 32;
const FADERS = [
  ["noiseReduction", "Noise", "Hiss, hum, air conditioning, crowd murmur."],
  ["dereverb", "Echo", "The big-room echo of a recording made in a theater."],
  ["dialogue", "Voice", "Cuts boom and mud, brings dialogue forward."],
  ["clarity", "Clarity", "Restores the crisp top end cheap mics lose."],
  ["bass", "Bass", "Adds back low end."],
  ["width", "Width", "Spreads the sound out. Turns mono into stereo."],
  ["leveling", "Level", "Quiet lines louder, explosions softer."],
];

// Preset icons, drawn on a 24-unit grid.
const ICONS = {
  cam: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M7 4v16M17 4v16M3 9h4M3 15h4M17 9h4M17 15h4"/>',
  telesync: '<path d="M3 12h1.5M7 8v8M10.5 5v14M14 9v6M17.5 7v10M21 12h-1"/>',
  quiet: '<path d="M4 9.5h3.5L12 6v12l-4.5-3.5H4z"/><path d="M15.5 9.5a3.5 3.5 0 0 1 0 5"/>',
  night: '<path d="M19 14.5A7.5 7.5 0 0 1 9.5 5a7.5 7.5 0 1 0 9.5 9.5z"/><path d="M17 3.5v3M15.5 5h3"/>',
  max: '<path d="M13 3L5 13.5h6L10 21l8-10.5h-6z"/>',
};

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
    ? s.isEnabled ? "Enhancing this tab" : "Playing the original"
    : state.activeTabId !== null ? "On in another tab" : "Off";
  $("legend-clean").hidden = !here || !s.isEnabled;

  const active = matchingPreset(s);
  $("preset-name").textContent = active ? active.name : "Custom";
  $("summary").textContent = active ? active.summary : "Your own settings.";
  for (const button of $("presets").children) {
    button.setAttribute("aria-checked", String(button.dataset.preset === active?.id));
  }
  for (const button of document.querySelectorAll(".segmented button")) {
    button.setAttribute("aria-checked", String(String(s.isEnabled) === button.dataset.enhanced));
  }

  const boost = $("boost");
  const fraction = (s.boostDB - BOOST_RANGE[0]) / (BOOST_RANGE[1] - BOOST_RANGE[0]);
  const label = s.boostDB >= 0.5 ? `+${Math.round(s.boostDB)} dB` : "Off";
  boost.style.setProperty("--f", fraction);
  boost.classList.toggle("boosting", s.boostDB >= 0.5);
  boost.classList.toggle("covered", fraction > 0.82);
  boost.querySelector("output").textContent = label;
  boost.setAttribute("aria-valuenow", s.boostDB);
  boost.setAttribute("aria-valuetext", label);

  for (const [key] of FADERS) {
    const fader = $(`fader-${key}`);
    fader.querySelector(".track").style.setProperty("--f", s[key]);
    fader.querySelector(".track").setAttribute("aria-valuenow", Math.round(s[key] * 100));
    fader.querySelector("b").textContent = Math.round(s[key] * 100);
  }
  $("stages").textContent = `${FADERS.filter(([key]) => s[key] >= 0.01).length}/${FADERS.length} on`;
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
  $("cleanup").textContent = !here ? "" : !state.settings.isEnabled ? "Bypassed" : removed >= 0.5 ? `−${Math.round(removed)} dB noise & echo` : "Listening…";
  drawBars(here ? Math.max(...state.spectrum.output) : -120);
  requestAnimationFrame(frame);
}

/** Four little bars that move with the loudest band. */
function drawBars(peakDB) {
  const level = Math.min(Math.max((peakDB + 70) / 50, 0), 1);
  const bars = $("bars");
  bars.classList.toggle("live", level > 0);
  [0.55, 1, 0.75, 0.45].forEach((weight, i) => { bars.children[i].style.height = `${3 + 8 * level * weight}px`; });
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

/** Pointer dragging and arrow keys for the pill and the faders. */
function makeAdjustable(element, { vertical, inset, step, get, set }) {
  const update = (event) => {
    const r = element.getBoundingClientRect();
    const f = vertical
      ? 1 - (event.clientY - r.top - inset) / (r.height - 2 * inset)
      : (event.clientX - r.left - inset) / (r.width - 2 * inset);
    set(Math.min(Math.max(f, 0), 1));
  };
  element.addEventListener("pointerdown", (event) => { element.setPointerCapture(event.pointerId); update(event); });
  element.addEventListener("pointermove", (event) => { if (element.hasPointerCapture(event.pointerId)) update(event); });
  element.addEventListener("keydown", (event) => {
    const delta = { ArrowUp: step, ArrowRight: step, ArrowDown: -step, ArrowLeft: -step }[event.key];
    if (delta === undefined) return;
    event.preventDefault();
    set(Math.min(Math.max(get() + delta, 0), 1));
  });
}

function buildControls() {
  $("presets").innerHTML = PRESETS.map((p) => `<button data-preset="${p.id}" role="radio" aria-checked="false" aria-label="${p.name}" title="${p.name}">
    <svg viewBox="0 0 24 24" aria-hidden="true">${ICONS[p.id]}</svg></button>`).join("");
  for (const button of $("presets").children) {
    button.addEventListener("click", () => {
      const preset = PRESETS.find((p) => p.id === button.dataset.preset);
      changeSettings({ ...preset.settings, isEnabled: state.settings.isEnabled });
    });
  }

  $("faders").innerHTML = FADERS.map(([key, name, help]) => `<div class="fader" id="fader-${key}" title="${help}">
    <b></b>
    <div class="track" role="slider" tabindex="0" aria-label="${name}" aria-valuemin="0" aria-valuemax="100">
      ${[0, 1, 2, 3, 4].map((i) => `<i class="tick" style="bottom: calc(8px + (100% - 16px) * ${i / 4})"></i>`).join("")}
      <div class="rail"></div><div class="level"></div><div class="knob"></div>
    </div>
    <span>${name}</span>
  </div>`).join("");
  for (const [key] of FADERS) {
    makeAdjustable($(`fader-${key}`).querySelector(".track"), {
      vertical: true, inset: 8, step: 0.05,
      get: () => state.settings[key],
      set: (f) => changeSettings({ ...state.settings, [key]: Math.round(f * 100) / 100 }),
    });
  }

  const boost = $("boost");
  const [low, high] = BOOST_RANGE;
  boost.setAttribute("aria-valuemin", low);
  boost.setAttribute("aria-valuemax", high);
  makeAdjustable(boost, {
    vertical: false, inset: 15, step: 1 / (high - low),
    get: () => (state.settings.boostDB - low) / (high - low),
    set: (f) => changeSettings({ ...state.settings, boostDB: Math.round((low + f * (high - low)) * 2) / 2 }),
  });

  for (const button of document.querySelectorAll(".segmented button")) {
    button.addEventListener("click", () => changeSettings({ ...state.settings, isEnabled: button.dataset.enhanced === "true" }));
  }

  const toggle = $("adjust-toggle");
  const setOpen = (open) => {
    toggle.setAttribute("aria-expanded", String(open));
    $("faders").hidden = !open;
    try { localStorage.setItem("adjustOpen", String(open)); } catch {}
  };
  let open = false;
  try { open = localStorage.getItem("adjustOpen") === "true"; } catch {}
  setOpen(open);
  toggle.addEventListener("click", () => setOpen(toggle.getAttribute("aria-expanded") !== "true"));
  $("power").addEventListener("change", togglePower);
}

// MARK: - On / off

async function togglePower() {
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
