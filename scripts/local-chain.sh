#!/usr/bin/env bash
# Local playground: starts anvil, deploys mock USDC + mock price feed + the vault, and writes
# .env.local so `pnpm dev` talks to it. The first anvil account is the operator.
#   pnpm chain        (leave running)      then in another terminal: pnpm dev
set -euo pipefail
cd "$(dirname "$0")/.."

anvil --silent &
ANVIL_PID=$!
trap 'kill $ANVIL_PID 2>/dev/null || true' EXIT
until cast block-number --rpc-url http://127.0.0.1:8545 >/dev/null 2>&1; do sleep 0.3; done

OUT=$(forge script contracts/script/DeployLocal.s.sol --rpc-url http://127.0.0.1:8545 --broadcast \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 2>&1)
VAULT=$(echo "$OUT" | awk '/VAULT/ {print $2; exit}')
[ -n "$VAULT" ] || { echo "$OUT"; echo "deploy failed"; exit 1; }

cat > .env.local <<ENV
VITE_CHAIN_ID=31337
VITE_VAULT_ADDRESS=$VAULT
TELEGRAM_INVITE_LINK=https://t.me/+local-test-invite
ENV

echo "Vault deployed at $VAULT  (written to .env.local)"
echo "Operator / test whale: anvil account #0. Use \"Local test wallet\" in the connect menu."
wait $ANVIL_PID
