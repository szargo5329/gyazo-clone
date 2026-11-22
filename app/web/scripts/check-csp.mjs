// Fails the build if dist/index.html contains anything the API's strict CSP would block:
// inline <script> bodies, inline event handlers, inline style attributes/blocks, or
// third-party script/style origins. The owner key lives in localStorage, so this matters.
import { readFileSync } from 'node:fs'

const html = readFileSync(new URL('../dist/index.html', import.meta.url), 'utf8')
const problems = []

for (const m of html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)) {
  const [, attrs, body] = m
  if (!/\bsrc=/.test(attrs) || body.trim() !== '') problems.push(`inline script: ${m[0].slice(0, 80)}`)
  const src = attrs.match(/\bsrc="([^"]+)"/)?.[1] ?? ''
  if (/^(https?:)?\/\//.test(src)) problems.push(`third-party script: ${src}`)
}
if (/<style\b/i.test(html)) problems.push('inline <style> block')
if (/\sstyle=/i.test(html)) problems.push('inline style attribute')
if (/\son[a-z]+=/i.test(html)) problems.push('inline event handler')
for (const m of html.matchAll(/<link\b[^>]*href="((?:https?:)?\/\/[^"]+)"/gi)) {
  problems.push(`third-party link: ${m[1]}`)
}

if (problems.length) {
  console.error('CSP check failed for dist/index.html:\n- ' + problems.join('\n- '))
  process.exit(1)
}
console.log('CSP check passed: no inline scripts, styles or handlers; same-origin assets only.')
