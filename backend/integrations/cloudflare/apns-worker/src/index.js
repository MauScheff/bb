/**
 * Turbo APNs sender Worker.
 *
 * The long-term goal is direct APNs-from-Unison once the hosted runtime can
 * negotiate HTTP/2 + ALPN and use the required crypto builtins. Until then,
 * this Worker is a transport adapter only: Turbo remains authoritative for
 * wake target selection and request intent.
 */

const JSON_HEADERS = { "content-type": "application/json; charset=utf-8" };
const APNS_JWT_REFRESH_INTERVAL_SECONDS = 30 * 60;

let cachedApnsJwt = null;
let cachedImportedSigningKey = null;

/**
 * @typedef {{
 *   TURBO_APNS_WORKER_SECRET: string
 *   TURBO_APNS_TEAM_ID: string
 *   TURBO_APNS_KEY_ID: string
 *   TURBO_APNS_PRIVATE_KEY: string
 *   TURBO_APNS_DEFAULT_BUNDLE_ID?: string
 *   TURBO_APNS_DEFAULT_USE_SANDBOX?: string
 * }} Env
 */

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
        service: "turbo-apns-sender",
        hasTeamId: Boolean(env.TURBO_APNS_TEAM_ID),
        hasKeyId: Boolean(env.TURBO_APNS_KEY_ID),
        hasPrivateKey: Boolean(env.TURBO_APNS_PRIVATE_KEY),
        defaultUseSandbox: resolveDefaultSandbox(env),
      });
    }

    if (request.method === "POST" && url.pathname === "/apns/send") {
      if (!isAuthorized(request, env)) {
        return jsonResponse(401, { error: "unauthorized" });
      }

      let body;
      try {
        body = await request.json();
      } catch {
        return jsonResponse(400, { error: "invalid-json" });
      }

      const validationError = validateSendRequest(body);
      if (validationError) {
        return jsonResponse(400, { error: validationError });
      }

      try {
        const result = await sendApns(body, env);
        return jsonResponse(result.ok ? 200 : 502, result);
      } catch (error) {
        return jsonResponse(500, {
          ok: false,
          result: "worker-exception",
          error: error instanceof Error ? error.message : String(error),
        });
      }
    }

    return jsonResponse(404, { error: "not-found" });
  },
};

/**
 * @param {Request} request
 * @param {Env} env
 */
function isAuthorized(request, env) {
  const expected = env.TURBO_APNS_WORKER_SECRET;
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
function validateSendRequest(body) {
  if (!body || typeof body !== "object") return "invalid-body";
  if (typeof body.token !== "string" || body.token.length === 0) return "missing-token";
  if (!body.payload || typeof body.payload !== "object") return "missing-payload";
  if (typeof body.pushType !== "string" || body.pushType.length === 0) return "missing-push-type";

  const topic = resolveTopic(body);
  if (!topic) return "missing-topic";

  return null;
}

/**
 * Generic APNs send route.
 *
 * Request body:
 * {
 *   "token": "...",
 *   "payload": { ... },
 *   "pushType": "pushtotalk" | "alert" | "background" | "...",
 *   "bundleId": "com.rounded.Turbo",
 *   "topic": "com.rounded.Turbo.voip-ptt",
 *   "topicSuffix": ".voip-ptt",
 *   "sandbox": true,
 *   "priority": 10,
 *   "expiration": 0,
 *   "collapseId": "optional",
 *   "apnsId": "optional",
 *   "metadata": { ... echoed back ... }
 * }
 *
 * The generic shape lets us reuse the same sender later for non-PTT pushes.
 *
 * @param {any} body
 * @param {Env} env
 */
async function sendApns(body, env) {
  const jwt = await currentApnsJwt(env);
  const topic = resolveTopic(body);
  const sandbox = resolveSandbox(body, env);
  const host = sandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com";
  const apnsUrl = `https://${host}/3/device/${body.token}`;

  /** @type {Record<string, string>} */
  const headers = {
    authorization: `bearer ${jwt}`,
    "apns-push-type": body.pushType,
    "apns-topic": topic,
    "content-type": "application/json",
    "apns-priority": String(body.priority ?? defaultPriority(body.pushType)),
    "apns-expiration": String(body.expiration ?? 0),
  };

  if (typeof body.collapseId === "string" && body.collapseId.length > 0) {
    headers["apns-collapse-id"] = body.collapseId;
  }
  if (typeof body.apnsId === "string" && body.apnsId.length > 0) {
    headers["apns-id"] = body.apnsId;
  }

  const startedAt = new Date().toISOString();
  const response = await fetch(apnsUrl, {
    method: "POST",
    headers,
    body: JSON.stringify(body.payload),
  });

  const responseText = await response.text();
  const apnsId = response.headers.get("apns-id");

  return {
    ok: response.ok,
    result: response.ok ? "sent" : "rejected",
    startedAt,
    status: response.status,
    apnsId,
    reason: parseApnsReason(responseText),
    body: responseText || "",
    resolvedSandbox: sandbox,
    resolvedHost: host,
    metadata: body.metadata ?? null,
  };
}

/**
 * @param {any} body
 */
function resolveTopic(body) {
  if (typeof body.topic === "string" && body.topic.length > 0) {
    return body.topic;
  }
  const bundleId = typeof body.bundleId === "string" && body.bundleId.length > 0
    ? body.bundleId
    : null;
  if (!bundleId) {
    return null;
  }
  const topicSuffix = typeof body.topicSuffix === "string" ? body.topicSuffix : "";
  return `${bundleId}${topicSuffix}`;
}

/**
 * @param {any} body
 * @param {Env} env
 */
function resolveSandbox(body, env) {
  if (typeof body.sandbox === "boolean") {
    return body.sandbox;
  }
  return resolveDefaultSandbox(env);
}

/**
 * @param {Env} env
 */
function resolveDefaultSandbox(env) {
  return parseBoolean(env.TURBO_APNS_DEFAULT_USE_SANDBOX ?? "true");
}

/**
 * @param {string} pushType
 */
function defaultPriority(pushType) {
  return pushType === "background" ? 5 : 10;
}

/**
 * @param {string} value
 */
function parseBoolean(value) {
  return !["0", "false", "no"].includes(value.toLowerCase());
}

/**
 * @param {string} text
 */
function parseApnsReason(text) {
  if (!text) return null;
  try {
    const parsed = JSON.parse(text);
    return typeof parsed.reason === "string" ? parsed.reason : null;
  } catch {
    return null;
  }
}

/**
 * @param {Env} env
 */
async function makeApnsJwt(env) {
  const teamId = must(env.TURBO_APNS_TEAM_ID, "Missing TURBO_APNS_TEAM_ID");
  const keyId = must(env.TURBO_APNS_KEY_ID, "Missing TURBO_APNS_KEY_ID");
  const issuedAt = nowInSeconds();
  const signingKey = await importedApnsSigningKey(env);
  return makeApnsJwtForSigningKey({ teamId, keyId, issuedAt, signingKey });
}

/**
 * Reuse the provider token for a bounded window instead of minting one per push.
 * Apple explicitly recommends token reuse; refreshing on every request can trigger
 * TooManyProviderTokenUpdates under bursty background traffic.
 *
 * @param {Env} env
 */
async function currentApnsJwt(env) {
  const teamId = must(env.TURBO_APNS_TEAM_ID, "Missing TURBO_APNS_TEAM_ID");
  const keyId = must(env.TURBO_APNS_KEY_ID, "Missing TURBO_APNS_KEY_ID");
  const privateKeyPem = must(env.TURBO_APNS_PRIVATE_KEY, "Missing TURBO_APNS_PRIVATE_KEY");
  const cacheKey = `${teamId}\u0000${keyId}\u0000${privateKeyPem}`;
  const issuedAt = nowInSeconds();

  if (
    cachedApnsJwt
    && cachedApnsJwt.cacheKey === cacheKey
    && issuedAt - cachedApnsJwt.issuedAt < APNS_JWT_REFRESH_INTERVAL_SECONDS
  ) {
    return cachedApnsJwt.token;
  }

  const token = await makeApnsJwt(env);
  cachedApnsJwt = { cacheKey, token, issuedAt };
  return token;
}

/**
 * @param {Env} env
 */
async function importedApnsSigningKey(env) {
  const privateKeyPem = must(env.TURBO_APNS_PRIVATE_KEY, "Missing TURBO_APNS_PRIVATE_KEY");
  if (
    cachedImportedSigningKey
    && cachedImportedSigningKey.privateKeyPem === privateKeyPem
  ) {
    return cachedImportedSigningKey.promise;
  }

  const promise = crypto.subtle.importKey(
    "pkcs8",
    pemToArrayBuffer(privateKeyPem),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  cachedImportedSigningKey = { privateKeyPem, promise };
  return promise;
}

/**
 * @param {{
 *   teamId: string,
 *   keyId: string,
 *   issuedAt: number,
 *   signingKey: CryptoKey
 * }} args
 */
async function makeApnsJwtForSigningKey({ teamId, keyId, issuedAt, signingKey }) {
  const header = { alg: "ES256", kid: keyId };
  const claims = { iss: teamId, iat: issuedAt };
  const encodedHeader = base64UrlEncode(utf8Bytes(JSON.stringify(header)));
  const encodedClaims = base64UrlEncode(utf8Bytes(JSON.stringify(claims)));
  const signingInput = `${encodedHeader}.${encodedClaims}`;
  const derSignature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    signingKey,
    utf8Bytes(signingInput),
  );
  const rawSignature = derToRawEcdsaSignature(new Uint8Array(derSignature), 32);
  return `${signingInput}.${base64UrlEncode(rawSignature)}`;
}

function nowInSeconds() {
  return Math.floor(Date.now() / 1000);
}

function resetCachesForTests() {
  cachedApnsJwt = null;
  cachedImportedSigningKey = null;
}

/**
 * @param {string} pem
 */
function pemToArrayBuffer(pem) {
  const base64 = pem
    .replace(/-----BEGIN PRIVATE KEY-----/g, "")
    .replace(/-----END PRIVATE KEY-----/g, "")
    .replace(/\s+/g, "");
  const bytes = Uint8Array.from(atob(base64), (char) => char.charCodeAt(0));
  return bytes.buffer;
}

/**
 * Convert ASN.1 DER ECDSA signature into raw r||s bytes for JWT ES256.
 *
 * @param {Uint8Array} der
 * @param {number} componentSize
 */
function derToRawEcdsaSignature(der, componentSize) {
  // Cloudflare/WebCrypto may already return raw IEEE P1363 r||s bytes.
  if (der.length === componentSize * 2) {
    return der;
  }

  if (der.length < 8 || der[0] !== 0x30) {
    throw new Error("Unexpected DER signature format");
  }

  let index = 2;
  if (der[1] & 0x80) {
    index = 2 + (der[1] & 0x7f);
  }

  if (der[index] !== 0x02) throw new Error("Missing DER integer for r");
  const rLen = der[index + 1];
  const r = der.slice(index + 2, index + 2 + rLen);
  index = index + 2 + rLen;

  if (der[index] !== 0x02) throw new Error("Missing DER integer for s");
  const sLen = der[index + 1];
  const s = der.slice(index + 2, index + 2 + sLen);

  return concatBytes(normalizeInt(r, componentSize), normalizeInt(s, componentSize));
}

/**
 * @param {Uint8Array} value
 * @param {number} size
 */
function normalizeInt(value, size) {
  let trimmed = value;
  while (trimmed.length > 0 && trimmed[0] === 0) {
    trimmed = trimmed.slice(1);
  }
  if (trimmed.length > size) {
    throw new Error("DER integer too large");
  }
  const out = new Uint8Array(size);
  out.set(trimmed, size - trimmed.length);
  return out;
}

/**
 * @param {Uint8Array} a
 * @param {Uint8Array} b
 */
function concatBytes(a, b) {
  const out = new Uint8Array(a.length + b.length);
  out.set(a, 0);
  out.set(b, a.length);
  return out;
}

/**
 * @param {string} value
 * @param {string} message
 */
function must(value, message) {
  if (!value) {
    throw new Error(message);
  }
  return value;
}

/**
 * @param {Uint8Array | ArrayBuffer} bytes
 */
function base64UrlEncode(bytes) {
  const raw = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let text = "";
  for (const byte of raw) {
    text += String.fromCharCode(byte);
  }
  return btoa(text).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

/**
 * @param {string} value
 */
function utf8Bytes(value) {
  return new TextEncoder().encode(value);
}

/**
 * Constant-time string equality for shared-secret header checks.
 *
 * @param {string} a
 * @param {string} b
 */
function timingSafeEqual(a, b) {
  const aBytes = utf8Bytes(a);
  const bBytes = utf8Bytes(b);
  if (aBytes.length !== bBytes.length) return false;
  let diff = 0;
  for (let index = 0; index < aBytes.length; index += 1) {
    diff |= aBytes[index] ^ bBytes[index];
  }
  return diff === 0;
}

/**
 * @param {number} status
 * @param {unknown} body
 */
function jsonResponse(status, body) {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: JSON_HEADERS,
  });
}

export const __test = {
  APNS_JWT_REFRESH_INTERVAL_SECONDS,
  currentApnsJwt,
  makeApnsJwt,
  resetCachesForTests,
  sendApns,
};
