// Runs the audio pipeline: captured tab audio → Unmuffle worklet → speakers.
// Capturing a tab mutes it, so what you hear is only the cleaned-up version.

let context = null;
let stream = null;
let node = null;
let metersPort = null;

async function start(streamId, settings) {
  stop();
  stream = await navigator.mediaDevices.getUserMedia({
    audio: { mandatory: { chromeMediaSource: "tab", chromeMediaSourceId: streamId } },
    video: false,
  });
  context = new AudioContext({ latencyHint: "interactive" });
  await context.audioWorklet.addModule("worklet.js");
  const source = context.createMediaStreamSource(stream);
  node = new AudioWorkletNode(context, "unmuffle", {
    numberOfInputs: 1,
    numberOfOutputs: 1,
    outputChannelCount: [2],
    processorOptions: { settings },
  });
  node.port.onmessage = (event) => metersPort?.postMessage(event.data);
  node.port.postMessage({ type: "meters", enabled: metersPort !== null });
  source.connect(node).connect(context.destination);
  await context.resume();

  // The tab was closed or navigated somewhere that ended the capture.
  stream.getAudioTracks()[0]?.addEventListener("ended", () => {
    stop();
    chrome.runtime.sendMessage({ target: "background", type: "ended" });
  });
}

function stop() {
  stream?.getTracks().forEach((track) => track.stop());
  context?.close();
  stream = null;
  context = null;
  node = null;
}

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.target !== "offscreen") return false;
  if (message.type === "start") {
    start(message.streamId, message.settings).then(
      () => sendResponse({ ok: true }),
      (error) => sendResponse({ ok: false, error: error.message || String(error) }),
    );
    return true;
  }
  if (message.type === "settings") node?.port.postMessage({ type: "settings", settings: message.settings });
  sendResponse({ ok: true });
  return false;
});

// The popup connects while it's open to draw the live spectrum.
chrome.runtime.onConnect.addListener((port) => {
  if (port.name !== "meters") return;
  metersPort = port;
  node?.port.postMessage({ type: "meters", enabled: true });
  port.onDisconnect.addListener(() => {
    metersPort = null;
    node?.port.postMessage({ type: "meters", enabled: false });
  });
});
