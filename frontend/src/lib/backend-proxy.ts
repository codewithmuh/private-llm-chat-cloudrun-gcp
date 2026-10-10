/**
 * Forwards /api/*, /admin/* and /django-static/* to Django (server-side only).
 *
 * WHY
 * The browser should see ONE origin: the login session is an HttpOnly cookie,
 * and Cloud Run gives the web and api services different addresses
 * (web-...run.app, api-...run.app). A cookie from one isn't sent to the other.
 * So the browser only ever talks to this web service, and these route
 * handlers pass API calls on to Django at API_ORIGIN, read at runtime:
 *
 *   browser ──► web (Next.js) ──► /api/…  ──► api (Django) at API_ORIGIN
 *
 *   local (docker compose)  API_ORIGIN=http://api:8000
 *   npm run dev             http://localhost:8000 (the default)
 *   Cloud Run               https://api-<project number>.<region>.run.app
 *
 * The answer is streamed straight through (chat answers are Server-Sent
 * Events), and the request is aborted upstream when the browser goes away
 * (the Stop button). Paths keep their trailing slash, which Django needs
 * (next.config.ts sets skipTrailingSlashRedirect).
 *
 * On Cloud Run the api is PRIVATE: Cloud Run only lets a request through with
 * a Google ID token for an identity allowed to call it, which is this web
 * service's own service account. API_AUTH=google-id-token (set by Terraform)
 * turns that on: the token comes from the metadata server and travels in
 * X-Serverless-Authorization, which Cloud Run checks and Django ignores.
 */
import type { NextRequest } from "next/server";

const API_ORIGIN = (process.env.API_ORIGIN || "http://localhost:8000").replace(/\/+$/, "");
const USE_ID_TOKEN = process.env.API_AUTH === "google-id-token";

/** A Google ID token for API_ORIGIN, from Cloud Run's metadata server, cached until shortly before it expires. */
let idToken: { value: string; expiresAt: number } | null = null;

async function googleIdToken(): Promise<string> {
  if (idToken && idToken.expiresAt - 5 * 60_000 > Date.now()) return idToken.value;
  // GCE_METADATA_HOST: the same override Google's own client libraries read (for tests).
  const host = process.env.GCE_METADATA_HOST || "metadata.google.internal";
  const url =
    `http://${host}/computeMetadata/v1/instance/service-accounts/default/identity` +
    `?audience=${encodeURIComponent(API_ORIGIN)}`;
  const response = await fetch(url, { headers: { "Metadata-Flavor": "Google" }, cache: "no-store" });
  if (!response.ok) throw new Error(`metadata server: HTTP ${response.status}`);
  const value = (await response.text()).trim();
  // The token is a JWT; its middle part says when it expires (seconds since 1970).
  const payload = JSON.parse(Buffer.from(value.split(".")[1], "base64url").toString()) as { exp?: number };
  idToken = { value, expiresAt: (payload.exp ?? Date.now() / 1000 + 3000) * 1000 };
  return value;
}

/** Request headers worth passing on (never Host: fetch sets the target's). */
const FORWARD_REQUEST = [
  "accept",
  "accept-language",
  "content-type",
  "cookie",
  "origin",
  "referer",
  "user-agent",
  "x-csrftoken",
  "x-forwarded-for",
  "x-request-id",
];

/** Response headers that describe the hop, not the content. */
const DROP_RESPONSE = new Set([
  "connection",
  "keep-alive",
  "transfer-encoding",
  // fetch() already decompressed the body, so these would be wrong.
  "content-encoding",
  "content-length",
  "set-cookie", // copied one by one below
]);

export async function forwardToApi(request: NextRequest): Promise<Response> {
  const target = `${API_ORIGIN}${request.nextUrl.pathname}${request.nextUrl.search}`;

  const headers = new Headers();
  for (const name of FORWARD_REQUEST) {
    const value = request.headers.get(name);
    if (value) headers.set(name, value);
  }
  // On Cloud Run, TLS ends in Google's front end, which says so in
  // X-Forwarded-Proto: this server itself only sees plain HTTP.
  headers.set("x-forwarded-proto", request.headers.get("x-forwarded-proto") ?? request.nextUrl.protocol.replace(":", ""));
  headers.set("x-forwarded-host", request.headers.get("host") ?? request.nextUrl.host);

  const hasBody = !["GET", "HEAD"].includes(request.method);
  let upstream: Response;
  try {
    if (USE_ID_TOKEN) headers.set("x-serverless-authorization", `Bearer ${await googleIdToken()}`);
    upstream = await fetch(target, {
      method: request.method,
      headers,
      // Uploads are at most a few MB (MAX_UPLOAD_MB), so buffering is fine.
      body: hasBody ? await request.arrayBuffer() : undefined,
      redirect: "manual", // pass Django's redirects (admin, signed file links) to the browser
      signal: request.signal,
      cache: "no-store",
    });
  } catch (error) {
    if (request.signal.aborted) return new Response(null, { status: 499 });
    console.error(`API not reachable at ${API_ORIGIN}:`, error);
    return Response.json(
      { error: "The API is not reachable. Is it running?", code: "api_unreachable" },
      { status: 502 },
    );
  }

  const responseHeaders = new Headers();
  upstream.headers.forEach((value, name) => {
    if (!DROP_RESPONSE.has(name.toLowerCase())) responseHeaders.set(name, value);
  });
  for (const cookie of upstream.headers.getSetCookie()) responseHeaders.append("set-cookie", cookie);

  return new Response(upstream.body, {
    status: upstream.status,
    statusText: upstream.statusText,
    headers: responseHeaders,
  });
}
