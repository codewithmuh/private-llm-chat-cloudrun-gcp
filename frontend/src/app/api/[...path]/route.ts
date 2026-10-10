/** Passed on to Django unchanged: see src/lib/backend-proxy.ts. */
import { forwardToApi } from "@/lib/backend-proxy";

export const dynamic = "force-dynamic";

export {
  forwardToApi as GET,
  forwardToApi as POST,
  forwardToApi as PUT,
  forwardToApi as PATCH,
  forwardToApi as DELETE,
  forwardToApi as HEAD,
  forwardToApi as OPTIONS,
};
