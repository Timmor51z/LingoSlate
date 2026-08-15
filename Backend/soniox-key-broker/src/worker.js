const SONIOX_TEMPORARY_KEY_URL =
  "https://api.soniox.com/v1/auth/temporary-api-key";

export default {
  fetch(request, env) {
    return handleRequest(request, env, fetch);
  },
};

export async function handleRequest(request, env, fetchUpstream) {
  const url = new URL(request.url);
  if (request.method === "GET" && url.pathname === "/health") {
    return json({ status: "ok" });
  }
  if (
    request.method !== "POST" ||
    url.pathname !== "/v1/soniox/temporary-key"
  ) {
    return json({ error: "not_found" }, 404);
  }

  if (!env.SONIOX_API_KEY || !env.LINGOSLATE_CLIENT_TOKEN) {
    return json({ error: "server_not_configured" }, 500);
  }
  const authorization = request.headers.get("Authorization") ?? "";
  const expected = `Bearer ${env.LINGOSLATE_CLIENT_TOKEN}`;
  if (!(await secureEqual(authorization, expected))) {
    return json({ error: "unauthorized" }, 401);
  }

  let upstream;
  try {
    upstream = await fetchUpstream(SONIOX_TEMPORARY_KEY_URL, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${env.SONIOX_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        usage_type: "transcribe_websocket",
        expires_in_seconds: 60,
        single_use: true,
        max_session_duration_seconds: 14_400,
        client_reference_id:
          env.CLIENT_REFERENCE_ID || "lingoslate-ios-personal",
      }),
    });
  } catch {
    return json({ error: "soniox_unavailable" }, 502);
  }

  const payload = await upstream.json().catch(() => null);
  if (!upstream.ok) {
    return json(
      { error: "soniox_rejected_request" },
      upstream.status === 429 ? 429 : 502,
    );
  }
  if (!payload?.api_key || !payload?.expires_at) {
    return json({ error: "invalid_soniox_response" }, 502);
  }
  return json({ api_key: payload.api_key, expires_at: payload.expires_at });
}

async function secureEqual(left, right) {
  const encoder = new TextEncoder();
  const [leftHash, rightHash] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(left)),
    crypto.subtle.digest("SHA-256", encoder.encode(right)),
  ]);
  const leftBytes = new Uint8Array(leftHash);
  const rightBytes = new Uint8Array(rightHash);
  let difference = 0;
  for (let index = 0; index < leftBytes.length; index += 1) {
    difference |= leftBytes[index] ^ rightBytes[index];
  }
  return difference === 0;
}

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
    },
  });
}
