import { createElement as h } from 'react';
import { ImageResponse } from '@vercel/og';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

// The card renderer. The element tree, dimensions, font, and colors are ported verbatim
// from web/scripts/render-og.mjs (itself ported from the retired netlify/functions/og.mts),
// so cards render identically to the build-time ones they replace.

const here = dirname(fileURLToPath(import.meta.url));

const fontData = readFileSync(
  join(here, 'assets/IBMPlexSansCondensed-Bold.ttf')
);

// The logo is baked into the image (assets/logo.png) rather than fetched per render, and
// inlined once as a data URI so satori doesn't refetch it. It must stay a PNG: satori can't
// decode webp/avif, and the transparency has to survive. Replace the file and redeploy to
// change it (and bump TEMPLATE_VERSION on the web side so cached cards refresh).
const logoDataUri = `data:image/png;base64,${readFileSync(
  join(here, 'assets/logo.png')
).toString('base64')}`;

function cardElement(title) {
  return h(
    'div',
    {
      style: {
        alignItems: 'center',
        backgroundColor: '#FFF',
        display: 'flex',
        flexFlow: 'column',
        height: '630px',
        justifyContent: 'center',
        position: 'relative',
        width: '1200px',
      },
    },
    [
      h('img', {
        src: logoDataUri,
        style: { margin: '1rem 0', width: '200px' },
      }),
      h(
        'h1',
        {
          style: {
            background: 'linear-gradient(180deg, #0F3557 0%, #030B11 100%)',
            backgroundClip: 'text',
            borderTop: '1px solid #EBEBEB',
            color: 'transparent',
            fontFamily: 'IBM Plex Sans Condensed',
            fontSize: '72px',
            margin: '1rem',
            padding: '1rem',
            position: 'relative',
            textAlign: 'center',
            textWrap: 'balance',
          },
        },
        title
      ),
    ]
  );
}

// Renders a 1200×630 PNG for the given title and returns its bytes.
export async function renderCard(title) {
  const response = new ImageResponse(cardElement(title), {
    width: 1200,
    height: 630,
    fonts: [
      {
        name: 'IBM Plex Sans Condensed',
        data: fontData,
        weight: 700,
        style: 'normal',
      },
    ],
  });
  return Buffer.from(await response.arrayBuffer());
}
