import assert from "node:assert/strict";
import test from "node:test";

import { handleRequest } from "../src/worker.js";

const endpoint = "https://broker.example/v1/soniox/temporary-key";
const env = {
  SONIOX_API_KEY: "permanent-secret",
  LINGOSLATE_CLIENT_TOKEN: "client-secret",
  CLIENT_REFERENCE_ID: "test-user",
};

test("health endpoint does not require credentials", async () => {
  const response = await handleRequest(
    new Request("https://broker.example/health"),
    {},
    failIfCalled,
  );
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { status: "ok" });
});

test("rejects an invalid client token without calling Soniox", async () => {
  const response = await handleRequest(
    new Request(endpoint, {
      method: "POST",
      headers: { Authorization: "Bearer wrong" },
    }),
    env,
    failIfCalled,
  );
  assert.equal(response.status, 401);
  assert.equal(response.headers.get("Cache-Control"), "no-store");
});

test("issues a restricted single-use transcription key", async () => {
  let captured;
  const response = await handleRequest(
    authorizedRequest(),
    env,
    async (url, options) => {
      captured = { url, options };
      return Response.json(
        { api_key: "temp:example", expires_at: "2026-07-22T07:00:00Z" },
        { status: 201 },
      );
    },
  );

  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {
    api_key: "temp:example",
    expires_at: "2026-07-22T07:00:00Z",
  });
  assert.equal(
    captured.url,
    "https://api.soniox.com/v1/auth/temporary-api-key",
  );
  assert.equal(
    captured.options.headers.Authorization,
    "Bearer permanent-secret",
  );
  assert.deepEqual(JSON.parse(captured.options.body), {
    usage_type: "transcribe_websocket",
    expires_in_seconds: 60,
    single_use: true,
    max_session_duration_seconds: 14_400,
    client_reference_id: "test-user",
  });
});

test("does not expose Soniox error details or the permanent key", async () => {
  const response = await handleRequest(
    authorizedRequest(),
    env,
    async () => Response.json(
      { message: "Incorrect API key permanent-secret" },
      { status: 401 },
    ),
  );
  const body = await response.text();

  assert.equal(response.status, 502);
  assert.equal(body.includes("permanent-secret"), false);
  assert.deepEqual(JSON.parse(body), { error: "soniox_rejected_request" });
});

test("preserves Soniox capacity errors for client retry handling", async () => {
  const response = await handleRequest(
    authorizedRequest(),
    env,
    async () => Response.json({ message: "limit" }, { status: 429 }),
  );
  assert.equal(response.status, 429);
});

function authorizedRequest() {
  return new Request(endpoint, {
    method: "POST",
    headers: { Authorization: "Bearer client-secret" },
  });
}

function failIfCalled() {
  throw new Error("Unexpected upstream request");
}
