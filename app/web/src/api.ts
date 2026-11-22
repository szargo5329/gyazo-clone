// Pure client logic, kept out of components so it's unit-testable.

export const ACCEPTED_TYPES = ['image/png', 'image/jpeg', 'image/gif', 'image/webp'] as const
export const KEY_STORAGE = 'gyazo-owner-key'

export type UploadResult = { id: string; url: string }

export class UploadError extends Error {
  readonly status: number
  constructor(status: number, message: string) {
    super(message)
    this.status = status
  }
}

/** First image file from a paste or drop, or null. The server re-checks magic bytes. */
export function pickImage(files: FileList | File[] | null | undefined): File | null {
  if (!files) return null
  for (const f of Array.from(files)) {
    if ((ACCEPTED_TYPES as readonly string[]).includes(f.type)) return f
  }
  return null
}

const MESSAGES: Record<number, string> = {
  401: 'The API key was rejected.',
  413: 'That file is too large (max 10 MB).',
  415: 'Only PNG, JPEG, GIF or WebP images are accepted.',
}

export async function uploadImage(
  file: File,
  apiKey: string,
  fetchImpl: typeof fetch = fetch,
): Promise<UploadResult> {
  const body = new FormData()
  body.append('file', file) // field name must match the API and the ShareX config
  const res = await fetchImpl('/upload', { method: 'POST', headers: { 'X-API-Key': apiKey }, body })
  if (!res.ok) throw new UploadError(res.status, MESSAGES[res.status] ?? `Upload failed (${res.status}).`)
  return (await res.json()) as UploadResult
}

export type ImageStatus = {
  id: string
  status: 'pending' | 'ready' | 'failed'
  width: number | null
  height: number | null
  thumbnail_url: string | null
}

export async function getStatus(id: string, fetchImpl: typeof fetch = fetch): Promise<ImageStatus> {
  const res = await fetchImpl(`/api/images/${encodeURIComponent(id)}`)
  if (!res.ok) throw new UploadError(res.status, `Status check failed (${res.status}).`)
  return (await res.json()) as ImageStatus
}

/** Poll until the worker finishes or the attempts run out; the link works either way. */
export async function waitForProcessing(
  id: string,
  { attempts = 15, intervalMs = 1000, fetchImpl = fetch as typeof fetch, sleep = defaultSleep } = {},
): Promise<ImageStatus> {
  let last = await getStatus(id, fetchImpl)
  for (let i = 1; i < attempts && last.status === 'pending'; i++) {
    await sleep(intervalMs)
    last = await getStatus(id, fetchImpl)
  }
  return last
}

const defaultSleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms))
