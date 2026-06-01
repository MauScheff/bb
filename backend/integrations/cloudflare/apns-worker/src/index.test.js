import test from "node:test";
import assert from "node:assert/strict";

import { __test } from "./index.js";

const env = {
  TURBO_APNS_WORKER_SECRET: "secret",
  TURBO_APNS_TEAM_ID: "TEAM123",
  TURBO_APNS_KEY_ID: "KEY123",
  TURBO_APNS_PRIVATE_KEY: "-----BEGIN PRIVATE KEY-----\nAA==\n-----END PRIVATE KEY-----",
};

test("currentApnsJwt reuses cached token within refresh window", async () => {
  const originalDateNow = Date.now;
  const originalImportKey = globalThis.crypto.subtle.importKey;
  const originalSign = globalThis.crypto.subtle.sign;

  let importCount = 0;
  let signCount = 0;
  let nowMs = 1_700_000_000_000;

  Date.now = () => nowMs;
  globalThis.crypto.subtle.importKey = async () => {
    importCount += 1;
    return { id: `key-${importCount}` };
  };
  globalThis.crypto.subtle.sign = async () => {
    signCount += 1;
    return new Uint8Array(64).fill(signCount).buffer;
  };

  __test.resetCachesForTests();

  try {
    const first = await __test.currentApnsJwt(env);
    const second = await __test.currentApnsJwt(env);

    assert.equal(first, second);
    assert.equal(importCount, 1);
    assert.equal(signCount, 1);

    nowMs += (__test.APNS_JWT_REFRESH_INTERVAL_SECONDS - 1) * 1000;
    const third = await __test.currentApnsJwt(env);
    assert.equal(third, first);
    assert.equal(signCount, 1);

    nowMs += 2_000;
    const fourth = await __test.currentApnsJwt(env);
    assert.notEqual(fourth, first);
    assert.equal(importCount, 1);
    assert.equal(signCount, 2);
  } finally {
    __test.resetCachesForTests();
    Date.now = originalDateNow;
    globalThis.crypto.subtle.importKey = originalImportKey;
    globalThis.crypto.subtle.sign = originalSign;
  }
});

test("sendApns reuses provider token across sends", async () => {
  const originalDateNow = Date.now;
  const originalFetch = globalThis.fetch;
  const originalImportKey = globalThis.crypto.subtle.importKey;
  const originalSign = globalThis.crypto.subtle.sign;

  let importCount = 0;
  let signCount = 0;
  let nowMs = 1_700_000_000_000;
  const authorizations = [];

  Date.now = () => nowMs;
  globalThis.crypto.subtle.importKey = async () => {
    importCount += 1;
    return { id: `key-${importCount}` };
  };
  globalThis.crypto.subtle.sign = async () => {
    signCount += 1;
    return new Uint8Array(64).fill(signCount).buffer;
  };
  globalThis.fetch = async (_url, options) => {
    authorizations.push(options.headers.authorization);
    return new Response("", {
      status: 200,
      headers: { "apns-id": "apns-123" },
    });
  };

  __test.resetCachesForTests();

  try {
    const body = {
      token: "device-token",
      payload: { aps: {} },
      pushType: "pushtotalk",
      bundleId: "com.rounded.Turbo",
      topicSuffix: ".voip-ptt",
      sandbox: true,
      metadata: { wakeAttemptId: "wake-1" },
    };

    const firstResult = await __test.sendApns(body, env);
    const secondResult = await __test.sendApns(body, env);

    assert.equal(importCount, 1);
    assert.equal(signCount, 1);
    assert.equal(authorizations.length, 2);
    assert.equal(authorizations[0], authorizations[1]);
    assert.equal(firstResult.resolvedSandbox, true);
    assert.equal(firstResult.resolvedHost, "api.sandbox.push.apple.com");
    assert.equal(secondResult.resolvedSandbox, true);
  } finally {
    __test.resetCachesForTests();
    Date.now = originalDateNow;
    globalThis.fetch = originalFetch;
    globalThis.crypto.subtle.importKey = originalImportKey;
    globalThis.crypto.subtle.sign = originalSign;
  }
});

test("sendApns honors explicit production environment", async () => {
  const originalDateNow = Date.now;
  const originalFetch = globalThis.fetch;
  const originalImportKey = globalThis.crypto.subtle.importKey;
  const originalSign = globalThis.crypto.subtle.sign;

  let requestedUrl = "";

  Date.now = () => 1_700_000_000_000;
  globalThis.crypto.subtle.importKey = async () => ({ id: "key" });
  globalThis.crypto.subtle.sign = async () => new Uint8Array(64).fill(1).buffer;
  globalThis.fetch = async (url) => {
    requestedUrl = String(url);
    return new Response("", { status: 200 });
  };

  __test.resetCachesForTests();

  try {
    const result = await __test.sendApns({
      token: "production-token",
      payload: { aps: {} },
      pushType: "pushtotalk",
      bundleId: "com.rounded.Turbo",
      topicSuffix: ".voip-ptt",
      sandbox: false,
    }, env);

    assert.equal(result.resolvedSandbox, false);
    assert.equal(result.resolvedHost, "api.push.apple.com");
    assert.equal(requestedUrl, "https://api.push.apple.com/3/device/production-token");
  } finally {
    __test.resetCachesForTests();
    Date.now = originalDateNow;
    globalThis.fetch = originalFetch;
    globalThis.crypto.subtle.importKey = originalImportKey;
    globalThis.crypto.subtle.sign = originalSign;
  }
});
