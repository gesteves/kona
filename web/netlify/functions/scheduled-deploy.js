import fetch from 'node-fetch';
import { schedule } from '@netlify/functions';

const BUILD_HOOK = process.env.BUILD_HOOK_URL;

/**
 * Scheduled function to trigger a Netlify build using a build webhook.
 * Runs once a day at 12:00 UTC (the cron expression is in UTC), which is roughly
 * 6 AM Mountain Time — 6 AM MDT in summer, 5 AM MST in winter (Netlify cron does
 * not observe DST). Now that the live widgets are served by the API, the site
 * only needs a daily rebuild to pick up new content.
 *
 * @returns {Object} Response object with status code.
 */
const handler = schedule('0 12 * * *', async () => {
  if (BUILD_HOOK) {
    await fetch(BUILD_HOOK, {
      method: 'POST',
    })
      .then((response) => {
        console.log(
          `Build hook response status: ${response.status} ${response.statusText}`
        );
      })
      .catch((error) => {
        console.error('Error in fetching build hook:', error);
      });
  }

  return {
    statusCode: 200,
  };
});

export { handler };
