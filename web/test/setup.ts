import { beforeAll, afterAll, afterEach } from 'vitest';
import { installFetchMock, resetFetchMock, pendingWaits } from './helpers';

// Route all outbound fetch() through the mock and forbid real network access, so any un-stubbed
// upstream call fails loudly instead of hitting the internet. Each test registers the interceptors
// it expects; resetFetchMock() then fails a test that registered one it never used.
let restoreFetch: () => void;

beforeAll(() => {
  restoreFetch = installFetchMock();
});

afterAll(() => {
  restoreFetch();
});

afterEach(async () => {
  // Let any ctx.waitUntil() background work (e.g. the Plausible script cache write) settle before
  // the pool tears down per-test storage, so it doesn't log a spurious abort.
  await Promise.allSettled(pendingWaits.splice(0));
  resetFetchMock();
});
