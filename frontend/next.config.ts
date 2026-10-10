import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // Build a self-contained server (.next/standalone/server.js) for the Docker
  // image: it bundles only the node_modules the app actually uses.
  output: "standalone",
  reactStrictMode: true,
  poweredByHeader: false,
  // Django's URLs end in "/" (/api/conversations/). Next.js would redirect
  // them to the slash-less form before src/lib/backend-proxy.ts could forward
  // them; src/proxy.ts still tidies up page URLs instead.
  skipTrailingSlashRedirect: true,

  async headers() {
    return [
      {
        source: "/:path*",
        headers: [
          { key: "X-Content-Type-Options", value: "nosniff" },
          { key: "X-Frame-Options", value: "DENY" },
          // Google Sign-In needs the page origin in the Referer header.
          { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
          { key: "Permissions-Policy", value: "camera=(), microphone=(self), geolocation=()" },
        ],
      },
    ];
  },
};

export default nextConfig;
