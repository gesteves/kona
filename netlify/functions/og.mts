import { createElement as h } from 'react';
import { ImageResponse } from '@vercel/og';
import type { Config, Context } from '@netlify/functions';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

type OgData = {
  logoUrl?: string;
  titles: Record<string, string>;
};

const projectRoot = process.cwd();

const ogData: OgData = JSON.parse(
  readFileSync(join(projectRoot, 'build/og/data.json'), 'utf-8')
);

const fontData = readFileSync(
  join(projectRoot, 'source/fonts/IBMPlexSansCondensed-Bold.ttf')
);

const siteOrigins = [process.env.URL, process.env.DEPLOY_URL]
  .filter((u): u is string => Boolean(u))
  .map((u) => new URL(u).origin);

function notFound() {
  return new Response('Not Found', {
    status: 404,
    headers: {
      'cache-control': 'public, max-age=300',
      'Netlify-Vary': 'query=url',
    },
  });
}

function normalizePath(pathname: string): string {
  const p = pathname.replace(/\/index\.html$/, '/');
  return p === '' ? '/' : p;
}

export default async function handler(
  req: Request,
  context: Context
): Promise<Response> {
  const { searchParams } = new URL(req.url);
  const targetUrl = searchParams.get('url');

  if (!targetUrl) {
    console.error('Missing URL parameter.');
    return notFound();
  }

  let target: URL;
  try {
    target = new URL(targetUrl);
  } catch {
    console.error('Invalid URL parameter:', targetUrl);
    return notFound();
  }

  if (siteOrigins.length === 0) {
    console.error('Site origin is not configured (URL / DEPLOY_URL env var).');
    return new Response('Internal Server Error', {
      status: 500,
      headers: { 'cache-control': 'public, max-age=60' },
    });
  }

  if (!siteOrigins.includes(target.origin)) {
    console.error('Invalid URL parameter (wrong origin):', targetUrl);
    return notFound();
  }

  const key = normalizePath(target.pathname);
  const title = ogData.titles[key];
  if (!title) {
    console.error('No title found for path:', key);
    return notFound();
  }

  try {
    const logoUrl = ogData.logoUrl;
    const children = [
      logoUrl
        ? h('img', {
            src: logoUrl,
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

    const element = h(
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

    console.info(
      [
        targetUrl,
        req.headers.get('User-Agent'),
        context.ip,
        context.geo?.city && context.geo?.country?.name
          ? `${context.geo.city}, ${context.geo.country.name}`
          : context.geo?.city || context.geo?.country?.name,
      ]
        .filter(Boolean)
        .join(' | ')
    );

    return new ImageResponse(element, {
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
      headers: {
        'content-type': 'image/png',
        'cache-control': 'public, max-age=60',
        'Netlify-CDN-Cache-Control':
          'public, durable, s-maxage=31536000, stale-while-revalidate=86400',
        'Netlify-Vary': 'query=url',
      },
    });
  } catch (error) {
    console.error('Error generating the image:', error);
    return new Response('Internal Server Error', {
      status: 500,
      headers: {
        'cache-control': 'public, max-age=60',
        'Netlify-Vary': 'query=url',
      },
    });
  }
}

export const config: Config = {
  path: '/og',
};
