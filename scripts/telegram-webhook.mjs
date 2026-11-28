// Points the bot at the deployed site, or checks or removes that.
//
//   node --env-file=.env.local scripts/telegram-webhook.mjs set https://your-site.vercel.app
//   node --env-file=.env.local scripts/telegram-webhook.mjs info
//   node --env-file=.env.local scripts/telegram-webhook.mjs delete
//
// Needs TELEGRAM_BOT_TOKEN and TELEGRAM_SECRET. Telegram sends TELEGRAM_SECRET back in a header on every
// update, which is how /api/telegram knows the call is real.
const [command, site] = process.argv.slice(2)
const token = process.env.TELEGRAM_BOT_TOKEN
const secret = process.env.TELEGRAM_SECRET
if (!token) throw new Error('Set TELEGRAM_BOT_TOKEN.')

const call = async (method, params = {}) => {
  const res = await fetch(`https://api.telegram.org/bot${token}/${method}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(params),
  })
  const body = await res.json()
  if (!body.ok) throw new Error(`${method}: ${body.description}`)
  return body.result
}

if (command === 'set') {
  if (!site || !/^https:\/\//.test(site)) throw new Error('Give the site address, starting with https://')
  if (!secret || !/^[A-Za-z0-9_-]{32,256}$/.test(secret)) throw new Error('Set TELEGRAM_SECRET (32+ characters of A-Z a-z 0-9 _ -).')
  const url = `${site.replace(/\/$/, '')}/api/telegram`
  await call('setWebhook', { url, secret_token: secret, allowed_updates: ['message', 'chat_join_request'] })
  console.log(`Webhook set: ${url}`)
} else if (command === 'info') {
  const info = await call('getWebhookInfo')
  console.log(JSON.stringify({ url: info.url, pending: info.pending_update_count, last_error: info.last_error_message ?? null }, null, 2))
} else if (command === 'delete') {
  await call('deleteWebhook')
  console.log('Webhook removed. Updates now wait for polling.')
} else {
  console.log('Usage: node --env-file=.env.local scripts/telegram-webhook.mjs set <https://site> | info | delete')
}
