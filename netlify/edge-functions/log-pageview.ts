import type { Context } from "@netlify/edge-functions";

export default async function handler(req: Request, context: Context) {
  if (req.method !== "POST") {
    return new Response("Method Not Allowed", { status: 405 });
  }

  try {
    const body = await req.json();
    const { page, referrer } = body;

    const userAgent = req.headers.get("User-Agent");
    const clientIP = context.ip;
    const country = context.geo?.country?.name;
    const city = context.geo?.city;

    const parts = [
      page,
      referrer,
      userAgent,
      clientIP,
      city && country ? `${city}, ${country}` : city || country,
    ].filter(Boolean);

    console.log(parts.join(" | "));

    return new Response(null, { status: 204 });
  } catch (error) {
    console.error("Error logging pageview:", error);
    return new Response(null, { status: 204 });
  }
}

export const config = {
  path: "/log-pageview",
};
