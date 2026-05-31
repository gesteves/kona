import type { Config } from '@netlify/functions';

// Serves /robots.txt at the edge instead of baking it at build time, so the Dark Visitors
// AI-scraper disallow list refreshes (daily, at the edge) without a site rebuild.
const DARK_VISITORS_API_URL = 'https://api.darkvisitors.com/robots-txts';

// Fetches the current AI-scraper disallow rules from Dark Visitors, or '' when unavailable.
async function darkVisitorsRules(): Promise<string> {
  const token = process.env.DARK_VISITORS_ACCESS_TOKEN;
  if (!token) return '';
  try {
    const response = await fetch(DARK_VISITORS_API_URL, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${token}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        agent_types: ['AI Data Scraper', 'Undocumented AI Agent'],
        disallow: '/',
      }),
    });
    if (!response.ok) return '';
    return (await response.text()).trim();
  } catch (error) {
    console.error('Dark Visitors fetch failed:', error);
    return '';
  }
}

export default async function handler(): Promise<Response> {
  const rules = await darkVisitorsRules();
  const sitemap = process.env.URL
    ? `Sitemap: ${process.env.URL}/sitemap.xml`
    : '';
  const body = `${[sitemap, rules].filter(Boolean).join('\n\n')}\n`;

  const headers: Record<string, string> = {
    'content-type': 'text/plain; charset=utf-8',
    'cache-control': 'public, max-age=0, must-revalidate',
  };
  if (rules) {
    // Hold a fresh copy at the edge for a day (refreshing well ahead of the monthly-ish agent-list
    // changes), and keep serving stale on a revalidation failure.
    headers['Netlify-CDN-Cache-Control'] =
      'public, durable, s-maxage=86400, stale-while-revalidate=86400, stale-if-error=86400';
  } else {
    // Degraded (no rules) — cache only briefly so it recovers quickly, never durably.
    headers['cache-control'] = 'public, max-age=300';
  }

  return new Response(body, { headers });
}

export const config: Config = {
  path: '/robots.txt',
};
