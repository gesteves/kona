import fetch from 'node-fetch'
import { schedule } from '@netlify/functions'
import isValidCron from 'cron-validator'

// Access environment variables
const BUILD_HOOK = process.env.BUILD_HOOK_URL
const CRON_SCHEDULE = process.env.BUILD_CRON_SCHEDULE

// Check if the necessary environment variables are set
if (!BUILD_HOOK || !CRON_SCHEDULE) {
  console.error('Error: The BUILD_HOOK_URL and/or BUILD_CRON_SCHEDULE environment variables are not set.')
  process.exit(1) // Exit with a failure code
}

// Validate the cron schedule
if (!isValidCron(CRON_SCHEDULE)) {
  console.error('Error: The CRON_SCHEDULE environment variable is not a valid cron expression.')
  process.exit(1) // Exit with a failure code
}

// Schedules the handler function to run based on the CRON_SCHEDULE environment variable
const handler = schedule(CRON_SCHEDULE, async () => {
  await fetch(BUILD_HOOK, {
    method: 'POST'
  }).then(response => {
    console.log('Build hook response:', response)
  }).catch(error => {
    console.error('Error in fetching build hook:', error)
  })

  return {
    statusCode: 200
  }
})

export { handler }
