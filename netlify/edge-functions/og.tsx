import React from "https://esm.sh/react@18.2.0";
import { ImageResponse } from "https://deno.land/x/og_edge/mod.ts";
import { DOMParser } from "https://deno.land/x/deno_dom@v0.1.49/deno-dom-wasm.ts";
import type { Context } from "@netlify/edge-functions";

export default async function handler(req: Request, context: Context) {
  const { searchParams } = new URL(req.url);
  const targetUrl = searchParams.get("url");

  if (!targetUrl) {
    console.error("Missing URL parameter.");
    return new Response("Not Found", {
      status: 404,
      headers: {
        "cache-control": "public, max-age=300",
        "Netlify-Vary": "query=url",
      },
    });
  }

  try {
    // Validate the target URL matches the site's base URL
    const target = new URL(targetUrl);
    const siteBaseUrl = new URL(context.site.url);
    if (target.origin !== siteBaseUrl.origin) {
      console.error("Invalid URL parameter:", targetUrl);
      return new Response("Not Found", {
        status: 404,
        headers: {
          "cache-control": "public, max-age=300",
          "Netlify-Vary": "query=url",
        },
      });
    }

    // Fetch the target page
    const pageResponse = await fetch(targetUrl);
    if (!pageResponse.ok) {
      console.error("Failed to fetch target URL", targetUrl, pageResponse.status);
      return new Response("Not Found", {
        status: 404,
        headers: {
          "cache-control": "public, max-age=300",
          "Netlify-Vary": "query=url",
        },
      });
    }

    const pageHtml = await pageResponse.text();

    // Parse the HTML and query specific selectors
    const document = new DOMParser().parseFromString(pageHtml, "text/html");
    if (!document) {
      throw new Error("Failed to parse HTML document");
    }

    // Get title from the og:title tag or <title> tag
    const ogTitleElement = document.querySelector('meta[property="og:title"]');
    const ogTitle = ogTitleElement?.getAttribute("content");

    const titleTag = document.querySelector("title");
    const title = ogTitle || titleTag?.textContent || null;

    // Fetch the config file
    const configResponse = await fetch(new URL("/og/config.json", context.site.url).href);
    if (!configResponse.ok) {
      throw new Error(`Failed to fetch config file: ${configResponse.statusText}`);
    }
    const config = await configResponse.json();

    const logoUrl = config.logoUrl;
    const fontsConfig = config.fonts || [];

    // Fetch font data for all fonts
    const fonts = await Promise.all(
      fontsConfig.map(async (fontConfig: { name: string; url: string; weight?: number; style: string }) => {
        const fontResponse = await fetch(fontConfig.url);
        if (!fontResponse.ok) {
          throw new Error(`Failed to fetch font: ${fontConfig.url}`);
        }
        const fontData = await fontResponse.arrayBuffer();
        return {
          name: fontConfig.name,
          data: fontData,
          weight: fontConfig.weight || 400,
          style: fontConfig.style as "normal" | "italic",
        };
      })
    );

    // Generate the Open Graph image
    const imageResponse = new ImageResponse(
      (
        <div
          style={{
            alignItems: "center",
            backgroundColor: "#FFF",
            display: "flex",
            flexFlow: "column",
            height: "630px",
            justifyContent: "center",
            position: "relative",
            width: "1200px",
          }}
        >
          {logoUrl && (
            <img
              src={logoUrl}
              style={{
                margin: "1rem 0",
                width: "200px",
              }}
            />
          )}

          {title && (
            <h1
              style={{
                background: "linear-gradient(180deg, #0F3557 0%, #030B11 100%)",
                backgroundClip: "text",
                borderTop: "1px solid #EBEBEB",
                color: "transparent",
                fontFamily: "IBM Plex Sans Condensed",
                fontSize: "72px",
                margin: "1rem",
                padding: "1rem",
                position: "relative",
                textAlign: "center",
                textWrap: "balance",
              }}
            >
              {title}
            </h1>
          )}
        </div>
      ),
      {
        width: 1200,
        height: 630,
        fonts: fonts.length > 0 ? fonts : undefined,
        headers: {
          "content-type": "image/png",
          "cache-control": "public, max-age=31536000, no-transform, immutable",
          "Netlify-Vary": "query=url",
        },
      }
    );

    console.info(targetUrl, req.headers.get("User-Agent"));
    return imageResponse;
  } catch (error) {
    console.error("Error generating the image:", error);
    return new Response("Internal Server Error", {
      status: 500,
      headers: {
        "cache-control": "public, max-age=300",
        "Netlify-Vary": "query=url",
      },
    });
  }
}

export const config = {
  path: "/og",
  cache: "manual",
};
