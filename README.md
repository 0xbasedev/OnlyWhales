# OnlyWhales

> Every whale needs a pool to splash in.
> Because liquidity needs a pool, and pools need a Telegram.

A whale vault on BNB Smart Chain. Lock USDC or BNB, pay the fee, get a soulbound pass that opens the Telegram. Leave early and you are slashed; the slash pays the whales who stayed.

**Status: unaudited. Do not deploy to mainnet until an outside audit is published.** The deploy script refuses chain 56 unless `OUTSIDE_AUDIT_REPORT_URL` is set.

## Layout

| Path | What |
| --- | --- |
| `contracts/src/OnlyWhalesVault.sol` | The vault: deposits, locks, slash, distribution, boost, timelock |
| `contracts/src/WhalePass.sol` | Soulbound pass (token id = holder address) |
| `contracts/src/lib/` | `TimeWeightedPot` (O(1) time-weighted payouts), `Timelocked` (self-executing delay) |
| `contracts/test/` | Foundry suite: unit, fuzz, invariant, regression, mainnet fork |
| `config/prelaunch.json` | Everything set at deploy, plus default site copy |
| `server/`, `api/` | Access gate, Telegram bot and branding API (Vercel functions; same handlers run in `vite dev`) |
| `src/` | Vite + React + wagmi/viem + GSAP frontend |

## Run it

```bash
pnpm install
git submodule update --init          # forge-std
pnpm chain                           # anvil + mock USDC/feed + vault, writes .env.local (leave running)
pnpm dev                             # http://localhost:5173  ("Local test wallet" in the connect menu)
```

Add `?operator` to the URL to connect as the operator on the local chain (`/owner?operator`).

```bash
forge test                                           # 123 contract tests
FOUNDRY_PROFILE=ci forge test                        # 5,000 fuzz runs, 256 x 200 invariant calls
BSC_RPC_URL=https://bsc-dataseed.binance.org forge test --mc ForkTest   # real USDC + real Chainlink feed
pnpm test:server                                     # access + branding API
pnpm build
```

After changing a contract: `forge build && pnpm abi`.

## Rules the contract enforces

- **Deposit** USDC (`0x8AC7…580d`, 18 decimals, $1) or BNB (Chainlink BNB/USD; rejects stale, zero/negative and incomplete rounds). Min and max are per wallet, in USD, across both pools, checked on the gross amount. One position per pool.
- **Fee** (default 3%) accrues to the DAO; anyone can call `sweepDao` to forward it. The DAO wallet is never paid inside a user's transaction, so a broken DAO address cannot block a withdrawal. Withdrawals never read the oracle.
- **Slash**: 100% at lock start, linear to 30% at lock end, 0% after. Locks end at 00:00 UTC.
- **Distribution**: 20% DAO, 80% to whales with 1,024+ locked days. Until one exists: 72% to stakers (weighted days staked x amount x lock length), 28% DAO. Empty pool: all to the DAO. Earnings are never slashed and are always claimable.
- **Boost** when a minimum raise lands: `1 + (new/old - 1) x min(days/1024, 1)`. Stacks, never decreases, capped at 100x.
- **Operator**: immutable address. Fee (0.5–3%), min/max ($10k–$1M), DAO wallet and pass artwork change only through a 7-day timelock that takes effect by itself. No pause, no proxy, no transfer, no renounce, no path to principal. `test_WriteSurface_IsExactlyThis` fails if a state-changing function is ever added.

### Decisions worth knowing about

These came out of an adversarial review and are deliberate:

1. **Expiry is exact.** Lock ends go into per-day buckets; the first transaction on or after that day removes the expired weight before any slash is distributed. An expired position earns nothing after its lock end, with no keeper.
2. **Letting a lock lapse costs you.** Relock before it ends and you keep everything. Relock after and your time weight restarts from zero (the day count is kept), and a 1,024-day whale rejoins the 80% pot 30 days into the new lock. Without this, a lapsed whale could sit liquid and relock one block ahead of someone else's slash.
3. **Only locked positions are boosted**, and the stacked boost is capped at 100x (the largest single raise the hard range allows), so cycling the minimum up and down buys nothing.
4. **Two things are applied lazily** (`sync`, permissionless): a boost that landed, and crossing 1,024 days. Both only ever help the position's owner; views show them immediately.
5. **Relocking restarts the slash curve at 100%.**

## Launch

1. Fill in `config/prelaunch.json`: `operator`, `daoWallet`, the ten `tierURIs` (`node scripts/gen-pass-art.mjs` writes default art to `public/pass/`; pin it), settings.
2. Get the outside audit.
3. `forge script contracts/script/Deploy.s.sol --rpc-url $RPC_URL --broadcast` (testnet first: set `network.chainId` to 97 and testnet addresses).
4. Set environment variables (see `.env.example`):
   - `VITE_CHAIN_ID`, `VITE_VAULT_ADDRESS` (public)
   - `TELEGRAM_BOT_TOKEN`, `TELEGRAM_BOT_USERNAME`, `TELEGRAM_CHAT_ID`, `TELEGRAM_SECRET` for the bot, or `TELEGRAM_INVITE_LINK` without it, and `RPC_URL` (server only; never `VITE_`-prefixed)
   - a Vercel Blob store (`BLOB_READ_WRITE_TOKEN`) or `BRANDING_FILE` on a persistent disk

### The Telegram gate

`POST /api/access { wallet, timestamp, signature }`. The server rebuilds the message from its own vault address and chain id, rejects timestamps older than five minutes, verifies the signature (EOA or ERC-1271) and calls `hasAccess(wallet)` on-chain. Only then does it return an invite:

- **With the bot** (all four `TELEGRAM_*` bot values set): a link to the bot carrying a start code for this wallet, signed with `TELEGRAM_SECRET`, valid for 10 minutes, usable once.
- **Without it**: `TELEGRAM_INVITE_LINK`, a shared link anyone can forward.

### The Telegram bot

`server/telegram.ts`. It enforces one wallet per seat inside the group:

1. The whale taps Start. The bot ties that Telegram account to the wallet and sends a join link.
2. The join link only asks to join. The bot approves accounts tied to a wallet where `hasAccess` is true and declines everyone else, so a forwarded link gets nobody in.
3. Every 15 minutes (`api/telegram-sweep.ts`, a private Vercel schedule) it re-checks every member. A wallet that lost access loses its seat and can come back by depositing again.
4. One wallet, one seat: tying a wallet to a second account removes the first. `/status` in a private chat shows a member their own position. The bot never reads or answers the group.

It only removes accounts it let in itself, so admins and anyone added by hand are left alone. If the chain cannot be read it admits nobody and removes nobody. The members file (Telegram id to wallet) is encrypted with a key derived from `TELEGRAM_SECRET` before it goes to Blob or disk; changing the secret makes it unreadable.

Set it up:

1. Message @BotFather, `/newbot`. Note the token and the username.
2. Make the group a private supergroup. Add the bot as an admin with **Invite users via link** and **Ban users**.
3. Get the group id: send a message in the group, then open `https://api.telegram.org/bot<token>/getUpdates` and read `chat.id`.
4. `TELEGRAM_SECRET`: `openssl rand -hex 32`.
5. Set the four values in Vercel, deploy, then point Telegram at the site:
   `node --env-file=.env.local scripts/telegram-webhook.mjs set https://your-site`
   (`info` shows the last delivery error, `delete` removes the webhook).

Locally, `pnpm dev` with the four values set runs the bot by polling, since Telegram cannot reach localhost. Use a separate test bot: a bot with a webhook set cannot poll, and dev stops rather than remove it. `node scripts/telegram-e2e.mjs` (with `pnpm chain` running) runs the whole flow against the local vault with a stand-in for Telegram.

### Operator page

`/owner`, gated to the on-chain `operator()`. Queue and cancel settings with live countdowns, sweep the DAO balance, and edit branding (title, logo, favicon, all copy). Branding is off-chain, signed by the operator wallet, and live immediately.

## Not verified here

- The Vercel deployment path (`api/*.ts`, Blob storage, the `telegram-sweep` schedule). The handlers are unit-tested and exercised through the dev server, but nothing was deployed to Vercel.
- The bot against real Telegram. It was run end to end against the local vault with a stand-in for the Bot API.
- WalletConnect (needs `VITE_WC_PROJECT_ID`) and real browser wallets; the browser runs used the local test wallet.
