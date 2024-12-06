import React from "https://esm.sh/react@18.2.0";
import { ImageResponse } from "https://deno.land/x/og_edge/mod.js";
import { DOMParser } from "https://deno.land/x/deno_dom/deno-dom-wasm.js";

export default async function handler(req, context) {
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
    const ogTitle = ogTitleElement ? ogTitleElement.getAttribute("content") : null;

    const titleTag = document.querySelector("title");
    const title = ogTitle || (titleTag ? titleTag.textContent : null);

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
      fontsConfig.map(async (fontConfig) => {
        const fontResponse = await fetch(fontConfig.url);
        if (!fontResponse.ok) {
          throw new Error(`Failed to fetch font: ${fontConfig.url}`);
        }
        const fontData = await fontResponse.arrayBuffer();
        return {
          name: fontConfig.name,
          data: fontData,
          weight: fontConfig.weight || 400,
          style: fontConfig.style,
        };
      })
    );

    // Generate the Open Graph image
    const imageResponse = new ImageResponse(
      React.createElement(
        "div",
        {
          style: {
            alignItems: "center",
            backgroundColor: "#FFF",
            display: "flex",
            flexFlow: "column",
            height: "630px",
            justifyContent: "center",
            position: "relative",
            width: "1200px",
          },
        },
        logoUrl &&
          React.createElement("img", {
            src: logoUrl,
            style: { margin: "1rem 0", width: "200px" },
          }),
        title &&
          React.createElement(
            "h1",
            {
              style: {
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
              },
            },
            title
          )
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

    console.info("Generated Open Graph image for URL:", targetUrl);
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
