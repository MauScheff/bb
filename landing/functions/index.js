"use strict";

const { onRequest } = require("firebase-functions/v2/https");
const { defineSecret, defineString } = require("firebase-functions/params");
const logger = require("firebase-functions/logger");

const birdAccessKey = defineSecret("BIRD_ACCESS_KEY");
const birdWorkspaceId = defineString("BIRD_WORKSPACE_ID");
const birdWaitlistListId = defineString("BIRD_WAITLIST_LIST_ID");
const birdEmailChannelId = defineString("BIRD_EMAIL_CHANNEL_ID");
const birdAuthScheme = defineString("BIRD_AUTH_SCHEME", { default: "AccessKey" });
const waitlistNotifyEmail = defineString("WAITLIST_NOTIFY_EMAIL");
const waitlistFromUsername = defineString("WAITLIST_FROM_USERNAME", { default: "hello" });
const waitlistFromDisplayName = defineString("WAITLIST_FROM_DISPLAY_NAME", { default: "Beep Beep" });

const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

function parseBody(req) {
  if (!req.body) return {};
  if (typeof req.body === "object") return req.body;

  try {
    return JSON.parse(req.body);
  } catch {
    return {};
  }
}

function json(res, status, body) {
  res.status(status).set("Cache-Control", "no-store").json(body);
}

function requiredConfig() {
  const values = {
    accessKey: birdAccessKey.value(),
    workspaceId: birdWorkspaceId.value(),
    waitlistListId: birdWaitlistListId.value(),
    emailChannelId: birdEmailChannelId.value(),
    notifyEmail: waitlistNotifyEmail.value(),
    authScheme: birdAuthScheme.value() || "AccessKey",
    fromUsername: waitlistFromUsername.value() || "hello",
    fromDisplayName: waitlistFromDisplayName.value() || "Beep Beep",
  };

  const missing = Object.entries(values)
    .filter(([, value]) => !value)
    .map(([key]) => key);

  return { values, missing };
}

async function birdFetch(path, config, options) {
  return fetch(new URL(path, "https://api.bird.com"), {
    ...options,
    headers: {
      "Authorization": `${config.authScheme} ${config.accessKey}`,
      "Content-Type": "application/json",
      "Accept": "application/json",
      ...(options.headers || {}),
    },
  });
}

async function upsertBirdContact(email, config) {
  const path = `/workspaces/${encodeURIComponent(config.workspaceId)}/contacts/identifiers/emailaddress/${encodeURIComponent(email)}`;
  const payload = {
    strategy: "strict_alias",
    addToLists: [config.waitlistListId],
  };

  return birdFetch(path, config, {
    method: "PATCH",
    body: JSON.stringify(payload),
  });
}

async function sendSignupNotification(email, config) {
  const payload = {
    receiver: {
      contacts: [
        {
          identifierKey: "emailaddress",
          identifierValue: config.notifyEmail,
          type: "to",
        }
      ],
    },
    body: {
      type: "html",
      html: {
        text: [
          "New Beep Beep waitlist signup",
          "",
          email,
          "",
          "They have been added to the pending waitlist in Bird.",
        ].join("\n"),
        html: [
          "<p>New Beep Beep waitlist signup:</p>",
          `<p><strong>${email}</strong></p>`,
          "<p>They have been added to the pending waitlist in Bird.</p>",
        ].join(""),
        metadata: {
          subject: `New Beep Beep waitlist signup: ${email}`,
          headers: {
            "reply-to": email,
          },
          emailFrom: {
            username: config.fromUsername,
            displayName: config.fromDisplayName,
          },
        },
      },
    },
    meta: {
      extraInformation: {
        useCase: "transactional",
        source: "beepbeep_landing",
        signupEmail: email,
      },
    },
    tags: ["beepbeep-waitlist"],
  };

  const path = `/workspaces/${encodeURIComponent(config.workspaceId)}/channels/${encodeURIComponent(config.emailChannelId)}/messages`;
  return birdFetch(path, config, {
    method: "POST",
    body: JSON.stringify(payload),
  });
}

exports.waitlist = onRequest(
  {
    region: "us-central1",
    maxInstances: 4,
    timeoutSeconds: 20,
    secrets: [birdAccessKey],
  },
  async (req, res) => {
    if (req.method === "OPTIONS") {
      res.set("Access-Control-Allow-Origin", req.get("Origin") || "*");
      res.set("Access-Control-Allow-Methods", "POST, OPTIONS");
      res.set("Access-Control-Allow-Headers", "Content-Type");
      res.status(204).send("");
      return;
    }

    if (req.method !== "POST") {
      json(res, 405, { ok: false, error: "method_not_allowed" });
      return;
    }

    const body = parseBody(req);
    if (body.company) {
      json(res, 200, { ok: true });
      return;
    }

    const email = String(body.email || "").trim().toLowerCase();
    if (!EMAIL_PATTERN.test(email) || email.length > 254) {
      json(res, 400, { ok: false, error: "invalid_email" });
      return;
    }

    const { values: config, missing } = requiredConfig();
    if (missing.length > 0) {
      logger.error("Bird waitlist configuration is incomplete", { missing });
      json(res, 500, { ok: false, error: "waitlist_not_configured" });
      return;
    }

    try {
      const contactResponse = await upsertBirdContact(email, config);
      if (!contactResponse.ok) {
        const text = await contactResponse.text();
        logger.error("Bird contact upsert failed", {
          status: contactResponse.status,
          body: text.slice(0, 800),
        });
        json(res, 502, { ok: false, error: "bird_contact_failed" });
        return;
      }

      const emailResponse = await sendSignupNotification(email, config);
      if (!emailResponse.ok) {
        const text = await emailResponse.text();
        logger.error("Bird signup notification failed", {
          status: emailResponse.status,
          body: text.slice(0, 800),
        });
        json(res, 502, { ok: false, error: "bird_email_failed" });
        return;
      }

      json(res, 200, { ok: true });
    } catch (error) {
      logger.error("Bird waitlist request failed", error);
      json(res, 502, { ok: false, error: "bird_request_failed" });
    }
  }
);
