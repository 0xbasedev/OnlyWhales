import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { WagmiProvider } from 'wagmi'
import { App } from './App'
import { BrandingProvider } from './hooks/useBranding'
import { wagmiConfig } from './lib/wagmi'
import './styles/index.css'

const queryClient = new QueryClient({ defaultOptions: { queries: { staleTime: 5_000, retry: 1 } } })

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={queryClient}>
        <BrandingProvider>
          <App />
        </BrandingProvider>
      </QueryClientProvider>
    </WagmiProvider>
  </StrictMode>,
)
