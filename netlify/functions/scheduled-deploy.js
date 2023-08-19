import fetch from 'node-fetch'
import { schedule } from '@netlify/functions'

const BUILD_HOOK = process.env.BUILD_HOOK_URL

if (!BUILD_HOOK) {
  console.error('Error: The BUILD_HOOK_URL environment variable is not set.')
  process.exit(1) // Exit with a failure code
}

const handler = schedule('0 12-23 * * *', async () => {
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
