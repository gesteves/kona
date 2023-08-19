import fetch from 'node-fetch'
import { schedule } from '@netlify/functions'

const BUILD_HOOK = process.env.BUILD_HOOK_URL

const handler = schedule('0 * * * *', async () => {
  // Convert current UTC hour to MDT (UTC-6)
  const currentHourMDT = (new Date().getUTCHours() - 6 + 24) % 24;

  // Check if current MDT hour is between 8 AM and 8 PM
  if (currentHourMDT >= 8 && currentHourMDT <= 20) && (BUILD_HOOK)) {
    await fetch(BUILD_HOOK, {
      method: 'POST'
    }).then(response => {
      console.log(`Build hook response status: ${response.status} ${response.statusText}`);
    }).catch(error => {
      console.error('Error in fetching build hook:', error)
    })
  }

  return {
    statusCode: 200
  }
})

export { handler }
