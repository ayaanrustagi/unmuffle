// Keeps track of which tab is being enhanced and owns the offscreen document that
// does the audio work (service workers can't run Web Audio).

const OFFSCREEN_URL = "offscreen.html";

async function ensureOffscreen() {
  if (await chrome.offscreen.hasDocument()) return;
  await chrome.offscreen.createDocument({
    url: OFFSCREEN_URL,
    reasons: ["USER_MEDIA"],
    justification: "Cleans up the tab's audio in real time.",
  });
}

async function getState() {
  const { activeTabId = null } = await chrome.storage.session.get("activeTabId");
  const { settings = null } = await chrome.storage.local.get("settings");
  return { activeTabId, settings };
}

async function setActiveTab(tabId) {
  const { activeTabId } = await getState();
  if (activeTabId !== null) chrome.action.setBadgeText({ tabId: activeTabId, text: "" }).catch(() => {});
  await chrome.storage.session.set({ activeTabId: tabId });
  if (tabId !== null) {
    chrome.action.setBadgeBackgroundColor({ tabId, color: "#7D5CFF" });
    chrome.action.setBadgeTextColor?.({ tabId, color: "#FFFFFF" });
    chrome.action.setBadgeText({ tabId, text: "ON" });
  }
}

async function stop() {
  if (await chrome.offscreen.hasDocument()) await chrome.offscreen.closeDocument();
  await setActiveTab(null);
}

// The offscreen document can take a moment to start listening after it's created.
async function sendToOffscreen(message, attempts = 5) {
  for (let attempt = 1; ; attempt++) {
    try {
      return await chrome.runtime.sendMessage({ target: "offscreen", ...message });
    } catch (error) {
      if (attempt >= attempts || !/Receiving end does not exist/.test(error.message)) throw error;
      await new Promise((resolve) => setTimeout(resolve, 50 * attempt));
    }
  }
}

async function start(tabId, streamId) {
  await ensureOffscreen();
  const { settings } = await getState();
  const result = await sendToOffscreen({ type: "start", streamId, settings });
  if (!result?.ok) {
    await stop();
    throw new Error(result?.error || "Couldn't start audio processing.");
  }
  await setActiveTab(tabId);
}

const handlers = {
  state: () => getState(),
  start: (message) => start(message.tabId, message.streamId).then(() => ({ ok: true })),
  stop: () => stop().then(() => ({ ok: true })),
  ended: () => stop().then(() => ({ ok: true })),
  settings: async (message) => {
    if (await chrome.offscreen.hasDocument()) {
      await sendToOffscreen({ type: "settings", settings: message.settings });
    }
    return { ok: true };
  },
};

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.target !== "background" || !handlers[message.type]) return false;
  handlers[message.type](message).then(sendResponse, (error) => sendResponse({ ok: false, error: error.message }));
  return true;
});

chrome.tabs.onRemoved.addListener(async (tabId) => {
  const { activeTabId } = await getState();
  if (tabId === activeTabId) await stop();
});
