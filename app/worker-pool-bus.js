import { EventEmitter } from "node:events";

import { createClient } from "redis";

import { buildWorkerPoolKeyPrefix } from "./worker-pool-store.js";

const PENDING_ASSIGNMENT_EVENT = "pending-assignment";

function getBusBackend(config) {
  return (
    config.workerPoolBusBackend ||
    config.signalBusBackend ||
    config.workerPoolStoreBackend ||
    config.sessionStoreBackend ||
    "memory"
  );
}

export function buildWorkerPoolPendingChannel(config = {}) {
  return `${config.workerPoolKeyPrefix || buildWorkerPoolKeyPrefix(config.redisKeyPrefix)}:pending`;
}

export class WorkerPoolBus {
  constructor(config = {}) {
    this.config = config;
    this.channel = config.workerPoolPendingChannel || buildWorkerPoolPendingChannel(config);
    this.emitter = new EventEmitter();
    this.publisher = null;
    this.subscriber = null;
  }

  async initialize() {
    if (getBusBackend(this.config) !== "redis") {
      return;
    }

    this.publisher = createClient({
      url: this.config.redisUrl,
      socket: {
        tls: this.config.redisTls,
      },
    });
    this.subscriber = this.publisher.duplicate();

    this.publisher.on("error", (error) => {
      console.error("[cloudsec-worker-pool-bus:publisher]", error);
    });
    this.subscriber.on("error", (error) => {
      console.error("[cloudsec-worker-pool-bus:subscriber]", error);
    });

    await this.publisher.connect();
    await this.subscriber.connect();

    await this.subscriber.subscribe(this.channel, (raw) => {
      const event = JSON.parse(raw);
      this.emitter.emit(PENDING_ASSIGNMENT_EVENT, event);
    });
  }

  onPendingAssignment(handler) {
    this.emitter.on(PENDING_ASSIGNMENT_EVENT, handler);
    return () => {
      this.emitter.off(PENDING_ASSIGNMENT_EVENT, handler);
    };
  }

  async notifyPendingAssignment(workerId) {
    const event = { workerId };
    const payload = JSON.stringify(event);

    if (this.publisher) {
      await this.publisher.publish(this.channel, payload);
      return;
    }

    this.emitter.emit(PENDING_ASSIGNMENT_EVENT, event);
  }

  async close() {
    if (this.subscriber) {
      await this.subscriber.quit();
      this.subscriber = null;
    }
    if (this.publisher) {
      await this.publisher.quit();
      this.publisher = null;
    }
    this.emitter.removeAllListeners();
  }
}
