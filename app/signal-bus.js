import { createClient } from "redis";

const DEFAULT_REDIS_KEY_PREFIX = "cloudsec-rbi";

function normalizeRedisKeyPrefix(prefix = DEFAULT_REDIS_KEY_PREFIX) {
  const value = String(prefix || DEFAULT_REDIS_KEY_PREFIX).trim().replace(/:+$/g, "");
  return value || DEFAULT_REDIS_KEY_PREFIX;
}

export function buildSignalBusChannel(redisKeyPrefix = DEFAULT_REDIS_KEY_PREFIX) {
  return `${normalizeRedisKeyPrefix(redisKeyPrefix)}:signals:pending`;
}

export class SignalBus {
  constructor(config) {
    this.config = config;
    this.channel = config.signalBusChannel || buildSignalBusChannel(config.redisKeyPrefix);
    this.handlers = new Set();
    this.publisher = null;
    this.subscriber = null;
  }

  async initialize() {
    if (this.config.signalBusBackend !== "redis") {
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
      console.error("[signal-bus:publisher]", error);
    });
    this.subscriber.on("error", (error) => {
      console.error("[signal-bus:subscriber]", error);
    });

    await this.publisher.connect();
    await this.subscriber.connect();

    await this.subscriber.subscribe(this.channel, (raw) => {
      const event = JSON.parse(raw);
      for (const handler of this.handlers) {
        handler(event);
      }
    });
  }

  onPendingSignal(handler) {
    this.handlers.add(handler);
    return () => {
      this.handlers.delete(handler);
    };
  }

  async notifyPendingSignal(sessionId, role) {
    const payload = JSON.stringify({ sessionId, role });

    if (this.publisher) {
      await this.publisher.publish(this.channel, payload);
      return;
    }

    for (const handler of this.handlers) {
      handler({ sessionId, role });
    }
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
  }
}
