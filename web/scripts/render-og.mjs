// Pre-renders every Open Graph card as a static PNG, replacing the runtime /og Netlify
// function: every input (title, logo, template) is a build-time constant, so a runtime
// render would recompute a constant on every crawler fetch. Runs from build.rake after
// `middleman build`, reading the freshly built build/og/data.json and writing one
// build/og/<page path>/card.png per entry — the same normalized path that
// generate_open_graph_image_url (lib/helpers/image_helpers.rb) keys on.
//
// Renders are cached in Redis keyed by a hash of (template version + logo URL + title),
// mirroring blurhash_jpeg_data_uri, so a warm build re-renders nothing. Without
// REDIS_URL every card renders from scratch — correct, just slower.

import { createElement as h } from 'react';
import { ImageResponse } from '@vercel/og';
import { createHash } from 'node:crypto';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { createClient } from 'redis';

// Bump to invalidate every cached card after changing the element tree below.
const TEMPLATE_VERSION = 'v1';

const projectRoot = process.cwd();
const ogData = JSON.parse(
  readFileSync(join(projectRoot, 'build/og/data.json'), 'utf-8')
);
const fontData = readFileSync(
  join(projectRoot, 'source/fonts/IBMPlexSansCondensed-Bold.ttf')
);

// The logo is fetched straight from Contentful (see source/og/data.json.erb) and inlined
// as a data URI so satori doesn't fetch it once per card. It must stay in its source
// format: satori can't decode webp or avif, and the PNG's transparency has to survive.
async function fetchLogoDataUri(url) {
  const response = await fetch(url);
  if (!response.ok)
    throw new Error(`Logo fetch failed: ${response.status} ${url}`);
  const type = response.headers.get('content-type') ?? 'image/png';
  const buffer = Buffer.from(await response.arrayBuffer());
  return `data:${type};base64,${buffer.toString('base64')}`;
}

// The card, ported verbatim from the retired netlify/functions/og.mts so existing cards
// render identically.
function cardElement(title, logoDataUri) {
  const children = [
    logoDataUri
      ? h('img', {
          src: logoDataUri,
          style: { margin: '1rem 0', width: '200px' },
        })
      : null,
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
  ].filter(Boolean);

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
    children
  );
}

async function renderCard(title, logoDataUri) {
  const response = new ImageResponse(cardElement(title, logoDataUri), {
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

async function main() {
  let redis = null;
  if (process.env.REDIS_URL) {
    try {
      redis = createClient({ url: process.env.REDIS_URL });
      await redis.connect();
    } catch (error) {
      console.warn(
        `OG cards: Redis unavailable, rendering all from scratch (${error.message})`
      );
      redis = null;
    }
  } else {
    console.warn('OG cards: REDIS_URL not set, rendering all from scratch');
  }

  const logoDataUri = ogData.logoUrl
    ? await fetchLogoDataUri(ogData.logoUrl)
    : null;
  const entries = Object.entries(ogData.titles);
  let rendered = 0;

  for (const [path, title] of entries) {
    // The cache key hashes every render input; the logo URL stands in for the logo bytes
    // because Contentful mints a new asset URL whenever the file is replaced.
    const digest = createHash('sha256')
      .update(JSON.stringify([TEMPLATE_VERSION, ogData.logoUrl, title]))
      .digest('hex');
    const cacheKey = `og:png:${digest}`;

    let png = null;
    const cached = await redis?.get(cacheKey);
    if (cached) {
      png = Buffer.from(cached, 'base64');
    } else {
      png = await renderCard(title, logoDataUri);
      rendered += 1;
      await redis?.set(cacheKey, png.toString('base64'));
    }

    const outfile = join(
      projectRoot,
      'build/og',
      ...path.split('/').filter(Boolean),
      'card.png'
    );
    mkdirSync(dirname(outfile), { recursive: true });
    writeFileSync(outfile, png);
  }

  await redis?.quit();
  console.log(
    `OG cards: ${entries.length} written (${rendered} rendered, ${entries.length - rendered} from cache)`
  );
}

main().catch((error) => {
  console.error('OG card rendering failed:', error);
  process.exit(1);
});
