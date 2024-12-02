import React from "https://esm.sh/react@18.2.0";
import { ImageResponse } from "https://deno.land/x/og_edge/mod.ts";
import type { Context } from "@netlify/edge-functions";

export default async function handler(req: Request, context: Context) {
  const { searchParams } = new URL(req.url);
  const rawText = searchParams.get("text");
  const rawLogoUrl = searchParams.get("logo");

  // Decode the parameters
  const text = rawText ? decodeURIComponent(rawText) : null;
  const logoUrl = rawLogoUrl ? decodeURIComponent(rawLogoUrl) : null;

  try {
    const font = await fetch(
      new URL("fonts/IBMPlexSansCondensed-Bold.ttf", context.site.url).href
    ).then((res) => {
      if (!res.ok) {
        throw new Error(`Failed to fetch font: ${res.status} ${res.statusText}`);
      }
      return res.arrayBuffer();
    });

    const imageResponse = new ImageResponse(
      (
        <div
          style={{
            width: "1200px",
            height: "630px",
            display: "flex",
            flexDirection: "column",
            justifyContent: "flex-end",
            alignItems: "flex-start",
            backgroundColor: "#FFFFFF",
            position: "relative",
            fontFamily: "IBM Plex Sans Condensed",
            padding: "20px"
          }}
        >
          <h1
            style={{
              fontSize: "72px",
              color: "#092034",
              textAlign: "left",
              width: "66%"
            }}
          >
            {text}
          </h1>
          {logoUrl && (
            <img
              src={logoUrl}
              alt="Logo"
              width="200"
              style={{
                position: "absolute",
                top: "20px",
                right: "20px",
              }}
            />
          )}
        </div>
      ),
      {
        width: 1200,
        height: 630,
        fonts: [
          {
            name: "IBM Plex Sans Condensed",
            data: font,
            style: "normal",
          },
        ],
      }
    );

    return imageResponse;
  } catch (error) {
    console.error("Error generating the image:", error);
    return new Response("Internal Server Error", { status: 500 });
  }
}

export const config = {
  path: "/og",
  cache: "manual",
};
