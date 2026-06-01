const JSON_HEADERS = { "content-type": "application/json; charset=utf-8" };

/**
 * @typedef {{
 *   TURBO_TELEMETRY_WORKER_SECRET: string
 *   TURBO_TELEMETRY_DISCORD_ALERTS_WEBHOOK?: string
 *   TURBO_TELEMETRY_DISCORD_DEV_WEBHOOK?: string
 *   TURBO_TELEMETRY_DISCORD_STREAM_WEBHOOK?: string
 *   TURBO_TELEMETRY_DISCORD_WEBHOOK?: string
 *   TURBO_TELEMETRY: AnalyticsEngineDataset
 * }} Env
 */

const SEVERITY_RANK = {
  debug: 0,
  info: 1,
  notice: 2,
  warning: 3,
  error: 4,
  critical: 5,
};

export default {
  /**
   * @param {Request} request
   * @param {Env} env
   * @returns {Promise<Response>}
   */
  async fetch(request, env) {
    const url = new URL(request.url);

    if (request.method === "GET" && url.pathname === "/health") {
      return jsonResponse(200, {
        ok: true,
        service: "turbo-telemetry",
        hasWorkerSecret: Boolean(env.TURBO_TELEMETRY_WORKER_SECRET),
        hasDiscordAlertsWebhook: Boolean(discordAlertsWebhook(env)),
        hasDiscordDevWebhook: Boolean(env.TURBO_TELEMETRY_DISCORD_DEV_WEBHOOK),
        hasDiscordStreamWebhook: Boolean(env.TURBO_TELEMETRY_DISCORD_STREAM_WEBHOOK),
        hasAnalyticsBinding: Boolean(env.TURBO_TELEMETRY),
      });
    }

    if (request.method === "POST" && url.pathname === "/telemetry/events") {
      if (!isAuthorized(request, env)) {
        return jsonResponse(401, { error: "unauthorized" });
      }

      let body;
      try {
        body = await request.json();
      } catch {
        return jsonResponse(400, { error: "invalid-json" });
      }

      const validationError = validateEvent(body);
      if (validationError) {
        return jsonResponse(400, { error: validationError });
      }

      const event = normalizeEvent(body);
      env.TURBO_TELEMETRY.writeDataPoint(buildAnalyticsPoint(event));

      const { alerted, devDelivered, streamed } = await deliverDiscord(event, env);

      return jsonResponse(202, {
        ok: true,
        status: "accepted",
        alerted,
        devDelivered,
        streamed,
        eventName: event.eventName,
        source: event.source,
        severity: event.severity,
      });
    }

    return jsonResponse(404, { error: "not-found" });
  },
};

/**
 * @param {Request} request
 * @param {Env} env
 */
function isAuthorized(request, env) {
  const expected = env.TURBO_TELEMETRY_WORKER_SECRET;
  if (!expected) {
    return false;
  }
  const provided = request.headers.get("x-turbo-worker-secret") ?? "";
  return timingSafeEqual(provided, expected);
}

/**
 * @param {unknown} body
 * @returns {string|null}
 */
function validateEvent(body) {
  if (!body || typeof body !== "object") return "invalid-body";
  if (!isNonEmptyString(body.eventName)) return "missing-event-name";
  if (!isNonEmptyString(body.source)) return "missing-source";
  if (!isNonEmptyString(body.severity)) return "missing-severity";
  if (body.metadata !== undefined && !isRecordOfStrings(body.metadata)) return "invalid-metadata";
  if (body.metadataText !== undefined && typeof body.metadataText !== "string") return "invalid-metadata-text";
  if (body.alert !== undefined && !isAlertValue(body.alert)) return "invalid-alert";
  if (body.devTraffic !== undefined && !isAlertValue(body.devTraffic)) return "invalid-dev-traffic";
  return null;
}

/**
 * @param {any} body
 */
function normalizeEvent(body) {
  const metadataText = normalizeMetadataText(body.metadata, body.metadataText);
  return {
    eventName: body.eventName,
    source: body.source,
    severity: body.severity,
    userId: stringOrEmpty(body.userId),
    userHandle: stringOrEmpty(body.userHandle),
    deviceId: stringOrEmpty(body.deviceId),
    sessionId: stringOrEmpty(body.sessionId),
    channelId: stringOrEmpty(body.channelId),
    peerUserId: stringOrEmpty(body.peerUserId),
    peerDeviceId: stringOrEmpty(body.peerDeviceId),
    peerHandle: stringOrEmpty(body.peerHandle),
    appVersion: stringOrEmpty(body.appVersion),
    backendVersion: stringOrEmpty(body.backendVersion),
    invariantId: stringOrEmpty(body.invariantId),
    phase: stringOrEmpty(body.phase),
    reason: stringOrEmpty(body.reason),
    message: stringOrEmpty(body.message),
    metadataText,
    devTraffic: parseAlert(body.devTraffic),
    alert: parseAlert(body.alert),
  };
}

/**
 * @param {ReturnType<typeof normalizeEvent>} event
 */
function buildAnalyticsPoint(event) {
  return {
    blobs: [
      event.eventName,
      event.source,
      event.severity,
      event.userId,
      event.userHandle,
      event.deviceId,
      event.sessionId,
      event.channelId,
      event.peerUserId,
      event.peerDeviceId,
      event.peerHandle,
      event.appVersion,
      event.backendVersion,
      event.invariantId,
      event.phase,
      event.reason,
      event.message,
      event.metadataText,
      event.devTraffic ? "true" : "false",
    ],
    doubles: [
      1,
      event.alert ? 1 : 0,
      severityScore(event.severity),
    ],
    indexes: [samplingKey(event)],
  };
}

/**
 * @param {ReturnType<typeof normalizeEvent>} event
 */
function shouldAlert(event) {
  return event.alert || severityScore(event.severity) >= SEVERITY_RANK.critical;
}

/**
 * @param {ReturnType<typeof normalizeEvent>} event
 * @param {Env} env
 */
async function deliverDiscord(event, env) {
  let alerted = false;
  let devDelivered = false;
  let streamed = false;

  const devWebhook = env.TURBO_TELEMETRY_DISCORD_DEV_WEBHOOK;
  if (event.devTraffic && devWebhook) {
    const deliveryKind = devDeliveryKind(event);
    if (!deliveryKind) {
      return { alerted, devDelivered, streamed };
    }
    try {
      devDelivered = await sendDiscordEvent(event, devWebhook, deliveryKind);
    } catch {
      devDelivered = false;
    }
    return { alerted, devDelivered, streamed };
  }

  const streamWebhook = env.TURBO_TELEMETRY_DISCORD_STREAM_WEBHOOK;
  if (streamWebhook && shouldStream(event)) {
    try {
      streamed = await sendDiscordEvent(event, streamWebhook, "stream");
    } catch {
      streamed = false;
    }
  }

  const alertsWebhook = discordAlertsWebhook(env);
  if (shouldAlert(event) && alertsWebhook) {
    try {
      alerted = await sendDiscordEvent(event, alertsWebhook, "alert");
    } catch {
      alerted = false;
    }
  }

  return { alerted, devDelivered, streamed };
}

/**
 * @param {Env} env
 */
function discordAlertsWebhook(env) {
  return env.TURBO_TELEMETRY_DISCORD_ALERTS_WEBHOOK || env.TURBO_TELEMETRY_DISCORD_WEBHOOK || "";
}

/**
 * Keep Discord as an operator feed, not a raw event firehose.
 *
 * @param {ReturnType<typeof normalizeEvent>} event
 */
function shouldStream(event) {
  switch (event.eventName) {
    case "backend.presence.heartbeat":
    case "ios.diagnostics.state_capture":
      return false;
    default:
      return true;
  }
}

/**
 * @param {ReturnType<typeof normalizeEvent>} event
 * @returns {"dev-alert" | "dev-stream" | null}
 */
function devDeliveryKind(event) {
  if (shouldAlert(event)) {
    return "dev-alert";
  }
  if (shouldStream(event)) {
    return "dev-stream";
  }
  return null;
}

/**
 * @param {ReturnType<typeof normalizeEvent>} event
 * @param {string} webhookUrl
 * @param {"alert" | "dev-alert" | "dev-stream" | "stream"} deliveryKind
 */
async function sendDiscordEvent(event, webhookUrl, deliveryKind) {
  const response = await fetch(webhookUrl, {
    method: "POST",
    headers: JSON_HEADERS,
    body: JSON.stringify({
      username: "Turbo Telemetry",
      allowed_mentions: { parse: [] },
      embeds: [
        {
          title: `${formatDeliveryKind(deliveryKind)} ${event.source} ${event.eventName}`,
          description: compactDescription(event),
          color: severityColor(event.severity),
          fields: compactFields(event),
          timestamp: new Date().toISOString(),
        },
      ],
    }),
  });
  return response.ok;
}

/**
 * @param {"alert" | "dev-alert" | "dev-stream" | "stream"} deliveryKind
 */
function formatDeliveryKind(deliveryKind) {
  return deliveryKind.replaceAll("-", " ").toUpperCase();
}

/**
 * @param {ReturnType<typeof normalizeEvent>} event
 */
function compactDescription(event) {
  return [
    event.message && `message=${event.message}`,
    event.reason && `reason=${event.reason}`,
    event.invariantId && `invariant=${event.invariantId}`,
  ]
    .filter(Boolean)
    .join("\n")
    .slice(0, 4000);
}

/**
 * @param {ReturnType<typeof normalizeEvent>} event
 */
function compactFields(event) {
  return [
    inlineField("severity", event.severity || "unknown"),
    inlineField("user", event.userHandle || event.userId || "unknown"),
    inlineField("device", event.deviceId || "none"),
    inlineField("channel", event.channelId || "none"),
    inlineField("peer", event.peerHandle || event.peerUserId || "none"),
    inlineField("source", event.source),
  ];
}

/**
 * @param {string} name
 * @param {string} value
 */
function inlineField(name, value) {
  return {
    name,
    value: truncate(value, 1000) || "none",
    inline: true,
  };
}

/**
 * @param {string} severity
 */
function severityScore(severity) {
  return SEVERITY_RANK[severity] ?? SEVERITY_RANK.info;
}

/**
 * @param {string} severity
 */
function severityColor(severity) {
  switch (severity) {
    case "critical":
      return 0xb42318;
    case "error":
      return 0xf04438;
    case "warning":
      return 0xf79009;
    case "notice":
      return 0x1570ef;
    default:
      return 0x667085;
  }
}

/**
 * @param {ReturnType<typeof normalizeEvent>} event
 */
function samplingKey(event) {
  return truncate(
    event.userId || event.deviceId || event.channelId || `${event.source}:${event.eventName}`,
    96,
  );
}

/**
 * @param {unknown} metadata
 * @param {unknown} metadataText
 */
function normalizeMetadataText(metadata, metadataText) {
  if (typeof metadataText === "string" && metadataText.length > 0) {
    return truncate(metadataText, 16_384);
  }
  if (isRecordOfStrings(metadata)) {
    return truncate(JSON.stringify(metadata), 16_384);
  }
  return "";
}

/**
 * @param {unknown} value
 */
function isAlertValue(value) {
  return typeof value === "boolean" || value === "true" || value === "false" || value === "1" || value === "0";
}

/**
 * @param {unknown} value
 */
function parseAlert(value) {
  return value === true || value === "true" || value === "1";
}

/**
 * @param {unknown} value
 */
function isRecordOfStrings(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return false;
  }
  return Object.values(value).every((entry) => typeof entry === "string");
}

/**
 * @param {unknown} value
 */
function isNonEmptyString(value) {
  return typeof value === "string" && value.length > 0;
}

/**
 * @param {unknown} value
 */
function stringOrEmpty(value) {
  return typeof value === "string" ? value : "";
}

/**
 * @param {string} value
 * @param {number} limit
 */
function truncate(value, limit) {
  return value.length > limit ? value.slice(0, limit) : value;
}

/**
 * @param {number} status
 * @param {unknown} payload
 */
function jsonResponse(status, payload) {
  return new Response(JSON.stringify(payload, null, 2), {
    status,
    headers: JSON_HEADERS,
  });
}

/**
 * @param {string} provided
 * @param {string} expected
 */
function timingSafeEqual(provided, expected) {
  const left = new TextEncoder().encode(provided);
  const right = new TextEncoder().encode(expected);
  if (left.length !== right.length) {
    return false;
  }
  let result = 0;
  for (let index = 0; index < left.length; index += 1) {
    result |= left[index] ^ right[index];
  }
  return result === 0;
}

export const __test = {
  buildAnalyticsPoint,
  compactDescription,
  devDeliveryKind,
  deliverDiscord,
  discordAlertsWebhook,
  formatDeliveryKind,
  normalizeEvent,
  normalizeMetadataText,
  sendDiscordEvent,
  severityScore,
  shouldAlert,
  shouldStream,
  validateEvent,
};
