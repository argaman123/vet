import type { Register } from 'claude-code'

// Talks to the Vet app over its Unix socket. Vet asks for drafts (review notes, "ask Claude
// about this") and this mod puts them in the message box. It never sends anything: you press
// send. When Vet isn't running every call fails quietly.

const SOCKET = '/Library/Application Support/Vet/bridge.sock'

let socketPath: string | undefined
let session: { sessionId: string; cwd: string } | undefined
let polling: { cancel(): void } | undefined

async function who($: any) {
  if (!socketPath) socketPath = (await $.env.get('HOME')) + SOCKET
  if (!session) session = { sessionId: await $.session.id(), cwd: await $.session.cwd() }
  return session
}

async function post($: any, path: string) {
  try {
    const s = await who($)
    await $.http.fetch('http://vet' + path, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(s),
      socketPath,
    })
  } catch {
    // Vet isn't running.
  }
}

async function poll($: any) {
  try {
    const s = await who($)
    const r = await $.http.fetch('http://vet/next?session=' + encodeURIComponent(s.sessionId), { socketPath })
    if (r.status !== 200) return
    const draft = JSON.parse(r.text) as { id: string; text: string }
    const filled = await $.prompt.fill({ text: draft.text, mode: 'append' })
    if (filled.isFilled) {
      await $.http.fetch('http://vet/ack', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ id: draft.id }),
        socketPath,
      })
    }
  } catch {
    // Vet isn't running; try again on the next tick.
  }
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const result = await next(e)
    await post($, '/hello')
    polling?.cancel()
    polling = $.clock.every(700, () => {
      void poll($)
    })
    return result
  })

  // The chat you last typed into is the one you're looking at, so drafts go there.
  on('prompt.submit', async ($, e, next) => {
    void post($, '/active')
    return next(e)
  })

  // Tells Vet a reply finished (not subagents), so Review can show what changed.
  on('turn.complete', async ($, e, next) => {
    const result = await next(e)
    if ((e as { agentId?: string }).agentId === undefined) void post($, '/turn-complete')
    return result
  })
}
