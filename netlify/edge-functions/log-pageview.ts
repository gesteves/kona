import type { Context } from "@netlify/edge-functions";

export default async function handler(req: Request, context: Context) {
  // Only accept POST requests
  if (req.method !== "POST") {
    return new Response("Method Not Allowed", { status: 405 });
  }

  try {
    const body = await req.json();
    const { page, referrer } = body;

    const userAgent = req.headers.get("User-Agent") || "Unknown";
    const clientIP = context.ip || "Unknown";
    const country = context.geo?.country?.name || "Unknown";
    const city = context.geo?.city || "Unknown";

    console.log(JSON.stringify({
      page,
      referrer: referrer || "Direct",
      userAgent,
      clientIP,
      country,
      city,
    }));

    return new Response(null, { status: 204 });
  } catch (error) {
    console.error("Error logging pageview:", error);
    return new Response(null, { status: 204 });
  }
}

export const config = {
  path: "/log-pageview",
};

