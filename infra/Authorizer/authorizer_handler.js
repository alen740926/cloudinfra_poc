// CommonJS Lambda authorizer with NO external deps (Node.js 18+)
// Verifies Azure AD v2 access tokens (RS256) using Web Crypto + JWKS

const TENANT_ID = process.env.TENANT_ID;         // e.g. d1df0ad0-...
const EXPECTED_AUD = process.env.EXPECTED_AUD;   // e.g. "api://<your-api-app-id-uri>"
const ISS_V2 = `https://login.microsoftonline.com/${TENANT_ID}/v2.0`;
const JWKS_URL = `https://login.microsoftonline.com/common/discovery/v2.0/keys`;

let cachedJwks; // simple in-memory cache for the container

exports.handler = async (event) => {
  try {
    // 1) Read token from header or authorizer test value
    let raw = event.authorizationToken || (event.headers && (event.headers.Authorization || event.headers.authorization)) || "";
    raw = Array.isArray(raw) ? raw[0] : raw;
    let token = String(raw).replace(/^Bearer\s+/i, "").trim().replace(/[\r\n]/g, "").replace(/^"+|"+$/g, "");
    if (token.split(".").length !== 3) throw new Error("Not a compact JWS (expect 3 segments)");

    // 2) Split and decode pieces
    const [hB64, pB64, sB64] = token.split(".");
    const header = JSON.parse(base64urlToUtf8(hB64));
    const payload = JSON.parse(base64urlToUtf8(pB64));
    if (header.alg !== "RS256") throw new Error(`Unsupported alg: ${header.alg}`);

    // 3) Basic claim checks (issuer, audience, exp/nbf)
    if (payload.iss !== ISS_V2) throw new Error(`Unexpected iss: ${payload.iss}`);
    if (payload.aud !== EXPECTED_AUD) throw new Error(`Unexpected aud: ${payload.aud}`);
    const now = Math.floor(Date.now() / 1000);
    if (typeof payload.nbf === "number" && now < payload.nbf) throw new Error("Token not yet valid (nbf)");
    if (typeof payload.exp !== "number" || now >= payload.exp) throw new Error("Token expired (exp)");

    // 4) Get public key from JWKS by kid
    const jwk = await getJwkByKid(header.kid);
    if (!jwk) throw new Error(`No JWK for kid: ${header.kid}`);

    // 5) Import key and verify signature
    const key = await crypto.subtle.importKey(
      "jwk",
      jwk,
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["verify"]
    );

    const verified = await crypto.subtle.verify(
      "RSASSA-PKCS1-v1_5",
      key,
      base64urlToUint8(sB64),
      new TextEncoder().encode(`${hB64}.${pB64}`)
    );
    if (!verified) throw new Error("Signature verification failed");

    // (Optional) roles/scope checks here, e.g. payload.roles includes "Api.Access"

    return allow(event.methodArn);
  } catch (err) {
    console.error("Auth error:", err.message);
    return deny(event.methodArn);
  }
};

function allow(resource) {
  return policy("Allow", resource);
}
function deny(resource) {
  return policy("Deny", resource);
}
function policy(effect, resource) {
  return {
    principalId: "user",
    policyDocument: {
      Version: "2012-10-17",
      Statement: [{ Action: "execute-api:Invoke", Effect: effect, Resource: resource }],
    },
  };
}

function base64urlToUtf8(b64u) {
  return new TextDecoder().decode(base64urlToUint8(b64u));
}
function base64urlToUint8(b64u) {
  // base64url -> base64
  const b64 = b64u.replace(/-/g, "+").replace(/_/g, "/") + "==".slice((2 - (b64u.length * 3) % 4) % 4);
  const bin = Buffer.from(b64, "base64");
  return new Uint8Array(bin.buffer, bin.byteOffset, bin.byteLength);
}

async function getJwkByKid(kid) {
  // fetch (or refresh if older than 60m)
  await ensureJwks();

  let jwk = findKey(kid);
  if (jwk) return jwk;

  // Force-refresh immediately (ignore cache) then try again
  await ensureJwks(true);
  jwk = findKey(kid);
  return jwk;
}

async function ensureJwks(force) {
  const maxAgeMs = 60 * 60 * 1000; // 1h
  if (force || !cachedJwks || Date.now() - cachedJwks.fetchedAt > maxAgeMs) {
    const res = await fetch(JWKS_URL);
    if (!res.ok) throw new Error(`Failed JWKS: ${res.status}`);
    const data = await res.json();
    cachedJwks = { keys: data.keys || [], fetchedAt: Date.now() };
  }
}

function findKey(kid) {
  return cachedJwks.keys.find(
    k => k.kid === kid && k.kty === "RSA" && (k.use === "sig" || !k.use) && (k.alg === "RS256" || !k.alg)
  );
}