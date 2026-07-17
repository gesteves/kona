import { createServer } from 'node:http';
import { renderCard } from './render.mjs';
import { fetchOgTitle, isAllowedOrigin } from './title.mjs';

// kona-og — on-demand Open Graph card renderer. Sits behind Cloudflare on its own host.
//
// Contract (see og/CLAUDE.md and the web helper generate_open_graph_image_url):
//   GET /og.png?url=<page url>&v=<template ver>-<publishedVersion>
//     → validate the url's origin, fetch that page, read its og:title, render a 1200×630
//       PNG, and serve it cached for a year. `v` is a pure cache buster — a republish bumps
//       publishedVersion, minting a new URL, so a title edit is picked up on next crawl
//       without any purge. This service ignores `v` entirely.
//   GET /up → health check.

const PORT = process.env.PORT || 3000;

// Content-addressed on (url, v), so the rendered PNG is immutable at a given URL.
const IMMUTABLE = 'public, max-age=31536000, immutable';
// Short TTL for the non-image responses, so a transient failure is never durably pinned.
const SHORT = 'public, max-age=300';

// The real visitor IP/ray for logs come from Cloudflare (this only ever runs behind the
// zone); Fly-Client-IP would be a Cloudflare PoP.
function logLine(req, ...parts) {
  return [
    ...parts,
    req.headers['cf-connecting-ip'],
    req.headers['cf-ray'],
  ]
    .filter(Boolean)
    .join(' | ');
}

function sendText(res, status, body, cacheControl = SHORT) {
  res.writeHead(status, {
    'content-type': 'text/plain; charset=utf-8',
    'cache-control': cacheControl,
  });
  res.end(body);
}

async function handleOg(req, res, url) {
  const target = url.searchParams.get('url');
  if (!target) return sendText(res, 400, 'Missing url parameter');

  let targetUrl;
  try {
    targetUrl = new URL(target);
  } catch {
    return sendText(res, 400, 'Invalid url parameter');
  }

  if (!isAllowedOrigin(targetUrl)) {
    return sendText(res, 403, 'Forbidden origin');
  }

  let title;
  try {
    title = await fetchOgTitle(targetUrl);
  } catch (error) {
    console.error(logLine(req, 'title fetch failed', target, String(error)));
    return sendText(res, 502, 'Could not fetch page');
  }
  if (!title) return sendText(res, 404, 'No title for page');

  try {
    const png = await renderCard(title);
    console.info(logLine(req, `200 /og.png`, target, title));
    res.writeHead(200, {
      'content-type': 'image/png',
      'content-length': png.length,
      'cache-control': IMMUTABLE,
      'cdn-cache-control': 'public, max-age=31536000',
    });
    res.end(png);
  } catch (error) {
    console.error(logLine(req, 'render failed', target, String(error)));
    return sendText(res, 500, 'Could not render image');
  }
}

const server = createServer(async (req, res) => {
  let url;
  try {
    url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  } catch {
    return sendText(res, 400, 'Bad request');
  }

  if (req.method === 'GET' && url.pathname === '/up') {
    return sendText(res, 200, 'ok', 'no-store');
  }
  if (req.method === 'GET' && url.pathname === '/og.png') {
    return handleOg(req, res, url);
  }
  return sendText(res, 404, 'Not found');
});

server.listen(PORT, () => {
  console.log(`kona-og listening on ${PORT}`);
});
