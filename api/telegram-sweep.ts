import { handleSchedule } from '@vercel/schedules'
import { runSweep } from '../server/telegram-env.js'

// Private: only Vercel's scheduler can call this (see "schedules" in vercel.json). Every 15 minutes it
// removes group members whose wallet no longer has a pass and an open position.
export const POST = handleSchedule(async (metadata) => {
  const removed = await runSweep(process.env)
  console.log(`telegram sweep ${metadata.executionId}: removed ${removed.length}`)
})
