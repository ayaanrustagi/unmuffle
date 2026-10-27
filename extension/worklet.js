// AudioWorklet wrapper around the Unmuffle engine.
import { Enhancer } from "./dsp.js";

class UnmuffleProcessor extends AudioWorkletProcessor {
  constructor(options) {
    super();
    this.enhancer = new Enhancer(sampleRate, options.processorOptions?.settings ?? undefined);
    this.metersEnabled = false;
    this.framesSinceMeters = 0;
    this.port.onmessage = ({ data }) => {
      if (data.type === "settings") this.enhancer.update(data.settings);
      if (data.type === "meters") this.metersEnabled = data.enabled;
    };
  }

  process(inputs, outputs) {
    const input = inputs[0];
    const [left, right] = outputs[0];
    if (input && input.length > 0) {
      left.set(input[0]);
      right.set(input[1] ?? input[0]);
    } else {
      left.fill(0);
      right.fill(0);
    }
    this.enhancer.process(left, right, left.length);

    if (this.metersEnabled) {
      this.framesSinceMeters += left.length;
      if (this.framesSinceMeters >= sampleRate / 30) {
        this.framesSinceMeters = 0;
        this.port.postMessage(this.enhancer.readMeters());
      }
    }
    return true;
  }
}

registerProcessor("unmuffle", UnmuffleProcessor);
