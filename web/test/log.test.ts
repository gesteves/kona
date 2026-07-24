import { describe, it, expect } from 'vitest';
import { requestLogLine } from '../src/log';

describe('requestLogLine', () => {
  it('joins the lead-in parts with referer, UA, IP, geo, and ray, pipe-separated', () => {
    const req = new Request('https://www.example.com/', {
      headers: {
        referer: 'https://ref.example/',
        'user-agent': 'TestUA/1.0',
        'cf-connecting-ip': '203.0.113.4',
        'cf-ray': 'ray-123',
      },
      cf: { city: 'Portland', country: 'US' },
    } as RequestInit);

    expect(requestLogLine(req, 'GET /', '→ 200')).toBe(
      'GET / | → 200 | https://ref.example/ | TestUA/1.0 | 203.0.113.4 | Portland, US | ray-123'
    );
  });

  it('omits missing fields (null/empty) rather than leaving blank segments', () => {
    const req = new Request('https://www.example.com/', {
      headers: { 'cf-connecting-ip': '203.0.113.4', 'cf-ray': 'ray-9' },
    });
    // No referer/UA, no request.cf → geo omitted entirely.
    expect(requestLogLine(req, 'GET /feed.xml', '→ 304')).toBe(
      'GET /feed.xml | → 304 | 203.0.113.4 | ray-9'
    );
  });
});
