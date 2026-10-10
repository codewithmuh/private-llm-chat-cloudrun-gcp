/**
 * Runs before every page request (Next.js "Proxy", formerly Middleware).
 *
 * next.config.ts turns off Next.js's own trailing-slash redirect, because the
 * Django paths (/api/, /admin/, /django-static/) need theirs. For the app's
 * pages, this puts the usual redirect back: /chat/ -> /chat.
 */
import { NextResponse, type NextRequest } from "next/server";

export function proxy(request: NextRequest) {
  const { pathname, search } = request.nextUrl;
  if (pathname.length > 1 && pathname.endsWith("/")) {
    // Built by hand: a cloned request.nextUrl would put the trailing slash
    // back (with skipTrailingSlashRedirect it remembers the request had one).
    // Behind Cloud Run this server only sees plain HTTP; the front end says
    // the browser's scheme in X-Forwarded-Proto.
    const proto = request.headers.get("x-forwarded-proto") ?? request.nextUrl.protocol.replace(":", "");
    const host = request.headers.get("host") ?? request.nextUrl.host;
    return NextResponse.redirect(new URL(pathname.replace(/\/+$/, "") + search, `${proto}://${host}`), 308);
  }
  return NextResponse.next();
}

export const config = {
  // Pages only: not Django's paths, Next.js's own files, or static assets.
  matcher: ["/((?!api/|admin|django-static/|_next/|healthz|.*\\.[a-zA-Z0-9]+$).*)"],
};
