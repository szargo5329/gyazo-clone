import { describe, expect, it, vi } from 'vitest'
import { UploadError, pickImage, uploadImage, waitForProcessing, type ImageStatus } from './api'

const file = (name: string, type: string) => new File([new Uint8Array([1, 2, 3])], name, { type })
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })

describe('pickImage', () => {
  it('returns the first accepted image', () => {
    const png = file('a.png', 'image/png')
    expect(pickImage([file('a.txt', 'text/plain'), png, file('b.gif', 'image/gif')])).toBe(png)
  })
  it.each([[null], [undefined], [[]], [[file('a.svg', 'image/svg+xml')]]])('returns null for %j', (input) => {
    expect(pickImage(input as File[] | null)).toBeNull()
  })
})

describe('uploadImage', () => {
  it('posts multipart field "file" with the key header and returns the link', async () => {
    const fetchImpl = vi.fn(async () => json({ id: 'abc', url: 'http://h/i/abc' }, 201))
    const result = await uploadImage(file('a.png', 'image/png'), 'k1', fetchImpl as typeof fetch)
    expect(result).toEqual({ id: 'abc', url: 'http://h/i/abc' })
    const [url, init] = fetchImpl.mock.calls[0] as unknown as [string, RequestInit]
    expect(url).toBe('/upload')
    expect(init.method).toBe('POST')
    expect(init.headers).toEqual({ 'X-API-Key': 'k1' })
    expect((init.body as FormData).get('file')).toBeInstanceOf(File)
  })

  it.each([
    [401, 'API key'],
    [413, 'too large'],
    [415, 'PNG, JPEG'],
    [500, '500'],
  ])('maps HTTP %i to a readable error', async (status, text) => {
    const fetchImpl = vi.fn(async () => json({ detail: 'x' }, status))
    const err = await uploadImage(file('a.png', 'image/png'), 'k', fetchImpl as typeof fetch).catch((e) => e)
    expect(err).toBeInstanceOf(UploadError)
    expect(err.status).toBe(status)
    expect(err.message).toContain(text)
  })
})

describe('waitForProcessing', () => {
  const status = (s: ImageStatus['status']): ImageStatus => ({
    id: 'abc',
    status: s,
    width: null,
    height: null,
    thumbnail_url: null,
  })

  it('polls until ready', async () => {
    const replies = [status('pending'), status('pending'), status('ready')]
    const fetchImpl = vi.fn(async () => json(replies.shift()))
    const sleep = vi.fn(async () => {})
    const result = await waitForProcessing('abc', { fetchImpl: fetchImpl as typeof fetch, sleep })
    expect(result.status).toBe('ready')
    expect(fetchImpl).toHaveBeenCalledTimes(3)
    expect(sleep).toHaveBeenCalledTimes(2)
  })

  it('stops after the attempt limit while still pending', async () => {
    const fetchImpl = vi.fn(async () => json(status('pending')))
    const result = await waitForProcessing('abc', {
      attempts: 3,
      fetchImpl: fetchImpl as typeof fetch,
      sleep: async () => {},
    })
    expect(result.status).toBe('pending')
    expect(fetchImpl).toHaveBeenCalledTimes(3)
  })
})
