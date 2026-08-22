import { beforeAll, afterAll, afterEach } from 'vitest';
import { installFetchMock, resetFetchMock, pendingWaits } from './helpers';

// Send each outbound fetch() to the mock and permit no true network access. Thus an upstream call
// with no stub fails with a message and does not reach the internet. Each test registers the
// intercepts that it expects, and resetFetchMock() then makes a test fail if it registered one that
// it never used.
let restoreFetch: () => void;

beforeAll(() => {
  restoreFetch = installFetchMock();
});

afterAll(() => {
  restoreFetch();
});

afterEach(async () => {
  // Wait for each ctx.waitUntil() background task to end, for example the cache write of the
  // Plausible script, before the pool removes the storage of the test. Thus the log gets no abort
  // message that means nothing.
  await Promise.allSettled(pendingWaits.splice(0));
  resetFetchMock();
});
