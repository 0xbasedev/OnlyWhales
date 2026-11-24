import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { dirname } from 'node:path'
import type { ServerEnv } from './env.js'

export interface Store {
  get(): Promise<string | null>
  set(value: string): Promise<void>
}

/** Local file. Used in dev and on any host with a persistent disk. */
export function fileStore(path: string): Store {
  return {
    async get() {
      try {
        return await readFile(path, 'utf8')
      } catch {
        return null
      }
    },
    async set(value) {
      await mkdir(dirname(path), { recursive: true })
      await writeFile(path, value, 'utf8')
    },
  }
}

/** Vercel Blob. Used automatically when BLOB_READ_WRITE_TOKEN is present. */
export function blobStore(token: string, pathname = 'onlywhales/branding.json'): Store {
  return {
    async get() {
      const { head } = await import('@vercel/blob')
      try {
        const meta = await head(pathname, { token })
        const res = await fetch(meta.url, { cache: 'no-store' })
        return res.ok ? await res.text() : null
      } catch {
        return null
      }
    },
    async set(value) {
      const { put } = await import('@vercel/blob')
      await put(pathname, value, {
        token,
        access: 'public',
        addRandomSuffix: false,
        allowOverwrite: true,
        contentType: 'application/json',
        cacheControlMaxAge: 0,
      })
    },
  }
}

export function storeFromEnv(env: ServerEnv): Store {
  if (env.BLOB_READ_WRITE_TOKEN) return blobStore(env.BLOB_READ_WRITE_TOKEN)
  return fileStore(env.BRANDING_FILE || 'data/branding.json')
}
