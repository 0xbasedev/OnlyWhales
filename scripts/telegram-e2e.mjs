// End-to-end check of the Telegram bot without Telegram.
//
//   pnpm chain                      # terminal 1, leave running
//   node scripts/telegram-e2e.mjs   # terminal 2
//
// Starts a small local server that stands in for Telegram's Bot API, starts `vite dev` (whose dev
// plugin runs the bot by polling), then with anvil's unlocked test account #2 (funded by pnpm chain): deposits USDC, signs the
// gate message, presses Start, asks to join, checks /status, withdraws early, and waits for the sweep.
// No real Telegram account and no private key are used.
import http from 'node:http'
import { spawn } from 'node:child_process'
import { readFileSync, rmSync } from 'node:fs'
import { createPublicClient, createWalletClient, erc20Abi, http as rpc, parseUnits } from 'viem'
import { foundry } from 'viem/chains'
import { accessMessage } from '../shared/messages.ts'

const RPC = 'http://127.0.0.1:8545'
const CHAT = '-100777'
const MEMBERS = '/tmp/onlywhales-telegram-e2e.json'
const env = Object.fromEntries(readFileSync('.env.local', 'utf8').split('\n').filter((l) => l.includes('=')).map((l) => l.split('=')))
const vault = env.VITE_VAULT_ADDRESS
const abiSrc = readFileSync('src/abi/vault.ts', 'utf8')
const vaultAbi = JSON.parse(abiSrc.slice(abiSrc.indexOf('['), abiSrc.lastIndexOf(']') + 1))

// ------------------------------------------------------------------ a stand-in for Telegram
const calls = []
const queue = []
let waiting = null
let nextId = 1
const push = (u) => {
  u.update_id = nextId++
  if (waiting) { const w = waiting; waiting = null; w([u]) } else queue.push(u)
}
const fake = http.createServer((req, res) => {
  let raw = ''
  req.on('data', (c) => (raw += c))
  req.on('end', async () => {
    const method = req.url.split('/').pop()
    const p = raw ? JSON.parse(raw) : {}
    let result = true
    if (method === 'getUpdates') {
      result = queue.length ? queue.splice(0) : await new Promise((r) => { waiting = r; setTimeout(() => { if (waiting === r) { waiting = null; r([]) } }, 1000) })
    } else {
      calls.push({ method, ...p })
      if (method === 'createChatInviteLink') result = { invite_link: 'https://t.me/+e2e-join' }
    }
    res.end(JSON.stringify({ ok: true, result }))
  })
}).listen(8899)

const wait = (ms) => new Promise((r) => setTimeout(r, ms))
const until = async (check, what, ms = 20_000) => {
  for (let t = 0; t < ms; t += 200) { if (check()) return; await wait(200) }
  throw new Error(`timed out waiting for ${what}`)
}
const said = (id) => calls.filter((c) => c.method === 'sendMessage' && c.chat_id === id).map((c) => c.text)

rmSync(MEMBERS, { force: true })
const vite = spawn('node_modules/.bin/vite', ['--port', '5199', '--strictPort'], {
  env: {
    ...process.env,
    TELEGRAM_BOT_TOKEN: 'e2e', TELEGRAM_BOT_USERNAME: 'OnlyWhalesE2EBot', TELEGRAM_CHAT_ID: CHAT,
    TELEGRAM_SECRET: 'e2e-secret-0123456789abcdefghijklmnopqrstuv', TELEGRAM_API_URL: 'http://127.0.0.1:8899',
    TELEGRAM_MEMBERS_FILE: MEMBERS, TELEGRAM_DEV_SWEEP_SECONDS: '2',
  },
  stdio: ['ignore', 'pipe', 'inherit'],
})
let viteOut = ''
vite.stdout.on('data', (d) => (viteOut += d))

let failed = false
try {
  await until(() => /polling for @OnlyWhalesE2EBot/.test(viteOut) && /Local/.test(viteOut), 'vite and the bot to start', 30_000)
  const pub = createPublicClient({ chain: foundry, transport: rpc(RPC) })
  const wallet = createWalletClient({ chain: foundry, transport: rpc(RPC) })
  const whale = (await wallet.getAddresses())[2]
  const send = async (args) => {
    const receipt = await pub.waitForTransactionReceipt({ hash: await wallet.writeContract({ account: whale, ...args }) })
    if (receipt.status !== 'success') throw new Error(`${args.functionName} reverted`)
  }

  const usdc = await pub.readContract({ address: vault, abi: vaultAbi, functionName: 'usdc' })
  await send({ address: usdc, abi: erc20Abi, functionName: 'approve', args: [vault, parseUnits('300000', 18)] })
  await send({ address: vault, abi: vaultAbi, functionName: 'depositUSDC', args: [parseUnits('300000', 18), 60n * 86400n] })
  console.log('1  deposited 300,000 USDC for 60 days; hasAccess =', await pub.readContract({ address: vault, abi: vaultAbi, functionName: 'hasAccess', args: [whale] }))

  const timestamp = Math.floor(Date.now() / 1000)
  const message = accessMessage({ wallet: whale, vault, chainId: 31337, timestamp })
  const signature = await wallet.signMessage({ account: whale, message })
  const r = await fetch('http://localhost:5199/api/access', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ wallet: whale, timestamp, signature }) })
  const { invite, error } = await r.json()
  if (!invite) throw new Error(`/api/access ${r.status}: ${error}`)
  console.log('2  /api/access', r.status, '->', invite.replace(/start=.*/, 'start=<code>'))

  push({ message: { chat: { type: 'private', id: 4242 }, from: { id: 4242 }, text: `/start ${invite.split('start=')[1]}` } })
  await until(() => said(4242).length >= 1, 'the welcome message')
  const link = calls.find((c) => c.method === 'createChatInviteLink')
  console.log('3  Start ->', link.creates_join_request ? 'request-to-join link' : 'OPEN LINK (wrong)', '|', said(4242)[0].split('\n')[0])

  push({ chat_join_request: { chat: { id: Number(CHAT) }, from: { id: 4242 }, user_chat_id: 4242 } })
  push({ chat_join_request: { chat: { id: Number(CHAT) }, from: { id: 6666 }, user_chat_id: 6666 } })
  await until(() => calls.some((c) => c.method === 'declineChatJoinRequest'), 'the join decisions')
  console.log('4  join: approved', calls.filter((c) => c.method === 'approveChatJoinRequest').map((c) => c.user_id), 'declined', calls.filter((c) => c.method === 'declineChatJoinRequest').map((c) => c.user_id))

  push({ message: { chat: { type: 'private', id: 4242 }, from: { id: 4242 }, text: '/status' } })
  await until(() => said(4242).length >= 2, '/status')
  console.log('5  /status ->\n     ' + said(4242).at(-1).replace(/\n/g, '\n     '))

  const stored = readFileSync(MEMBERS, 'utf8')
  console.log('6  members file encrypted:', !stored.toLowerCase().includes(whale.slice(2, 12).toLowerCase()) && !stored.includes('4242'))

  // A day later, so the early exit costs a little less than everything.
  await pub.request({ method: 'evm_increaseTime', params: [86400] })
  await pub.request({ method: 'evm_mine', params: [] })
  await send({ address: vault, abi: vaultAbi, functionName: 'withdraw', args: [0] })
  console.log('7  withdrew early; hasAccess =', await pub.readContract({ address: vault, abi: vaultAbi, functionName: 'hasAccess', args: [whale] }))
  await until(() => calls.some((c) => c.method === 'unbanChatMember'), 'the sweep')
  console.log('8  sweep removed', calls.filter((c) => c.method === 'banChatMember').map((c) => c.user_id), '| told:', said(4242).at(-1))
} catch (err) {
  failed = true
  console.log('FAILED:', err.message)
} finally {
  vite.kill()
  fake.close()
  rmSync(MEMBERS, { force: true })
  process.exit(failed ? 1 : 0)
}
