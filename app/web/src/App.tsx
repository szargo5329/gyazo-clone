import { useCallback, useEffect, useRef, useState } from 'react'
import { KEY_STORAGE, UploadError, pickImage, uploadImage, waitForProcessing, type ImageStatus } from './api'

type State =
  | { kind: 'idle' }
  | { kind: 'uploading' }
  | { kind: 'done'; url: string; status: ImageStatus | null }
  | { kind: 'error'; message: string }

function readKey(): string {
  try {
    return localStorage.getItem(KEY_STORAGE) ?? ''
  } catch {
    return ''
  }
}

export default function App() {
  const [apiKey, setApiKey] = useState(readKey)
  const [state, setState] = useState<State>({ kind: 'idle' })
  const [dragging, setDragging] = useState(false)
  const [copied, setCopied] = useState(false)
  const input = useRef<HTMLInputElement>(null)

  const saveKey = (value: string) => {
    setApiKey(value)
    try {
      localStorage.setItem(KEY_STORAGE, value)
    } catch {
      /* storage blocked: key lasts for this tab only */
    }
  }

  const send = useCallback(
    async (file: File | null) => {
      if (!file) {
        setState({ kind: 'error', message: 'Choose a PNG, JPEG, GIF or WebP image.' })
        return
      }
      if (!apiKey) {
        setState({ kind: 'error', message: 'Enter your API key first.' })
        return
      }
      setState({ kind: 'uploading' })
      setCopied(false)
      try {
        const { id, url } = await uploadImage(file, apiKey)
        setState({ kind: 'done', url, status: null })
        const status = await waitForProcessing(id)
        setState({ kind: 'done', url, status })
      } catch (e) {
        const message = e instanceof UploadError ? e.message : 'Upload failed. Is the API running?'
        setState({ kind: 'error', message })
      }
    },
    [apiKey],
  )

  // Paste anywhere on the page (the Gyazo flow: screenshot → Ctrl+V).
  useEffect(() => {
    const onPaste = (e: ClipboardEvent) => {
      const file = pickImage(e.clipboardData?.files)
      if (file) {
        e.preventDefault()
        void send(file)
      }
    }
    window.addEventListener('paste', onPaste)
    return () => window.removeEventListener('paste', onPaste)
  }, [send])

  const copy = async (url: string) => {
    await navigator.clipboard.writeText(url)
    setCopied(true)
  }

  return (
    <main>
      <h1>gyazo-clone</h1>

      <label className="key">
        API key
        <input
          type="password"
          autoComplete="off"
          value={apiKey}
          onChange={(e) => saveKey(e.target.value)}
          placeholder="owner key"
        />
      </label>

      <button
        type="button"
        className={dragging ? 'drop dragging' : 'drop'}
        onClick={() => input.current?.click()}
        onDragOver={(e) => {
          e.preventDefault()
          setDragging(true)
        }}
        onDragLeave={() => setDragging(false)}
        onDrop={(e) => {
          e.preventDefault()
          setDragging(false)
          void send(pickImage(e.dataTransfer.files))
        }}
      >
        Paste, drop or click to choose an image
      </button>
      <input
        ref={input}
        type="file"
        accept="image/png,image/jpeg,image/gif,image/webp"
        hidden
        onChange={(e) => void send(pickImage(e.target.files))}
      />

      <section aria-live="polite">
        {state.kind === 'uploading' && <p>Uploading…</p>}
        {state.kind === 'error' && <p className="error">{state.message}</p>}
        {state.kind === 'done' && (
          <div className="result">
            <div className="link">
              <a href={state.url} target="_blank" rel="noreferrer">
                {state.url}
              </a>
              <button type="button" onClick={() => void copy(state.url)}>
                {copied ? 'Copied' : 'Copy'}
              </button>
            </div>
            <p className="muted">
              {state.status === null && 'Processing…'}
              {state.status?.status === 'pending' && 'Still processing; the link already works.'}
              {state.status?.status === 'failed' && 'Thumbnail failed; the link still works.'}
              {state.status?.status === 'ready' &&
                `Ready · ${state.status.width}×${state.status.height}`}
            </p>
            {state.status?.thumbnail_url && <img src={state.status.thumbnail_url} alt="Thumbnail" />}
          </div>
        )}
      </section>
    </main>
  )
}
