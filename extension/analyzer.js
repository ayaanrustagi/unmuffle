// Spectrum analyzer drawing, shared by the Chrome extension popup and the web demo.
// Mirrors SpectrumView in the Mac app: dark display, dB and frequency grid, the
// original as a dim filled curve, the cleaned-up audio as an accent line.

const LOW_HZ = 50;
const HIGH_HZ = 16000;
const FLOOR_DB = -90;
const CEILING_DB = -10;

function smoothPath(ctx, points) {
  ctx.moveTo(points[0][0], points[0][1]);
  for (let i = 0; i < points.length - 1; i++) {
    const [x0, y0] = points[Math.max(i - 1, 0)];
    const [x1, y1] = points[i];
    const [x2, y2] = points[i + 1];
    const [x3, y3] = points[Math.min(i + 2, points.length - 1)];
    ctx.bezierCurveTo(x1 + (x2 - x0) / 6, y1 + (y2 - y0) / 6, x2 - (x3 - x1) / 6, y2 - (y3 - y1) / 6, x2, y2);
  }
}

export function drawAnalyzer(canvas, { input, output, active, enhanced, accent }) {
  const ratio = window.devicePixelRatio || 1;
  const width = canvas.clientWidth;
  const height = canvas.clientHeight;
  if (canvas.width !== Math.round(width * ratio) || canvas.height !== Math.round(height * ratio)) {
    canvas.width = Math.round(width * ratio);
    canvas.height = Math.round(height * ratio);
  }
  const ctx = canvas.getContext("2d");
  ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
  ctx.clearRect(0, 0, width, height);

  const top = 8, bottom = height - 16, left = 0, right = width;
  const x = (hz) => left + (Math.log(hz / LOW_HZ) / Math.log(HIGH_HZ / LOW_HZ)) * (right - left);
  const y = (db) => top + (1 - (Math.min(Math.max(db, FLOOR_DB), CEILING_DB) - FLOOR_DB) / (CEILING_DB - FLOOR_DB)) * (bottom - top);

  // Grid
  ctx.lineWidth = 1;
  ctx.strokeStyle = "rgba(255,255,255,0.07)";
  ctx.fillStyle = "rgba(255,255,255,0.32)";
  ctx.font = "9px ui-monospace, SFMono-Regular, Menlo, monospace";
  ctx.textBaseline = "middle";
  for (const db of [-20, -40, -60, -80]) {
    const gy = Math.round(y(db)) + 0.5;
    ctx.beginPath(); ctx.moveTo(left, gy); ctx.lineTo(right, gy); ctx.stroke();
    ctx.fillText(String(db).replace("-", "−"), left + 4, gy - 6);
  }
  ctx.textBaseline = "alphabetic";
  for (const [hz, label] of [[100, "100"], [1000, "1k"], [10000, "10k"]]) {
    const gx = Math.round(x(hz)) + 0.5;
    ctx.beginPath(); ctx.moveTo(gx, top); ctx.lineTo(gx, bottom); ctx.stroke();
    ctx.fillText(label, gx + 3, height - 4);
  }

  const bands = input.length;
  const center = (b) => LOW_HZ * Math.pow(HIGH_HZ / LOW_HZ, (b + 0.5) / bands);
  const curve = (values) => values.map((db, b) => [x(center(b)), active ? y(db) : bottom]);

  // Original: dim filled area.
  const original = curve(input);
  ctx.beginPath();
  smoothPath(ctx, original);
  ctx.lineTo(original.at(-1)[0], bottom);
  ctx.lineTo(original[0][0], bottom);
  ctx.closePath();
  ctx.fillStyle = active ? "rgba(255,255,255,0.10)" : "rgba(255,255,255,0.04)";
  ctx.fill();
  ctx.beginPath();
  smoothPath(ctx, original);
  ctx.strokeStyle = "rgba(255,255,255,0.32)";
  ctx.lineWidth = 1;
  ctx.stroke();

  // What you hear: accent line.
  if (active && enhanced) {
    const cleaned = curve(output);
    ctx.beginPath();
    smoothPath(ctx, cleaned);
    ctx.strokeStyle = accent;
    ctx.lineWidth = 1.75;
    ctx.lineJoin = "round";
    ctx.stroke();
  }
}

/** Average gap between the two curves, in dB. Same number the Mac app shows. */
export function removedDB(input, output) {
  let sum = 0;
  for (let i = 0; i < input.length; i++) sum += Math.max(input[i] - output[i], 0);
  return sum / input.length;
}
