import { createConfig, http } from 'wagmi'
import { injected, mock, walletConnect } from 'wagmi/connectors'
import { chain, isLocalChain, rpcUrl, wcProjectId } from './config'

const connectors = [
  injected({ shimDisconnect: true }),
  ...(wcProjectId ? [walletConnect({ projectId: wcProjectId, showQrModal: true })] : []),
  // Local anvil only: the node's unlocked accounts, so the whole flow can be driven without
  // a browser wallet.
  ...(isLocalChain
    ? [
        mock({
          // A funded whale by default; add ?operator to the URL to act as the operator instead.
          accounts: new URLSearchParams(window.location.search).has('operator')
            ? ['0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266']
            : ['0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC'],
          features: { reconnect: true },
        }),
      ]
    : []),
]

export const wagmiConfig = createConfig({
  chains: [chain],
  connectors,
  transports: { [chain.id]: http(rpcUrl) } as Record<typeof chain.id, ReturnType<typeof http>>,
})

declare module 'wagmi' {
  interface Register {
    config: typeof wagmiConfig
  }
}
