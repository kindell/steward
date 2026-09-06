// watch/resume.mjs - the shared resume engine for the watch (the automatic
// path) and restart-session (the escalation path). Keystrokes are sent ONLY
// from here, and only as the resume sequence, a hub notice, or the redelivery
// of stuck input - never free text of its own into a conversation.
//
// THE SOCKET IS THE ESTATE'S (TMUX_SOCKET) and arrives as an argument; the
// estate's copy carried it as a literal.
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { resumeStep, paneBusy } from './lib.mjs'

const exec = promisify(execFile)
export const RESUME_MAX_STEPS = 6
export const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

export async function capturePane(sock, session) {
  try {
    const { stdout } = await exec('tmux', ['-S', sock, 'capture-pane', '-t', session, '-p'])
    return stdout
  } catch { return null }
}

export async function tmuxSendLiteral(sock, session, text) {
  await exec('tmux', ['-S', sock, 'send-keys', '-t', session, '-l', '--', text])
}

export async function tmuxSendEnter(sock, session) {
  await exec('tmux', ['-S', sock, 'send-keys', '-t', session, 'Enter'])
}

// Run the /resume procedure for a session on a fresh, idle start screen. Every
// iteration takes a FRESH capture before deciding the next step (resumeStep is
// the pure decision) - abort on anything but the expected states.
export async function runResume(sock, session) {
  let lastPane = null
  for (let i = 0; i < RESUME_MAX_STEPS; i++) {
    lastPane = await capturePane(sock, session)
    const { action, reason } = resumeStep(lastPane)
    if (action === 'done') return { ok: true, paneText: lastPane }
    if (action === 'abort') return { ok: false, reason, paneText: lastPane }
    if (action === 'escape') {
      // close the modal FIRST - an abort with the picker open leaves the
      // session deaf to every message (the keystroke is a bare Escape, never text)
      await exec('tmux', ['-S', sock, 'send-keys', '-t', session, 'Escape'])
      return { ok: false, reason, paneText: lastPane }
    }
    if (action === 'type-resume') {
      await tmuxSendLiteral(sock, session, '/resume')
      await sleep(1500)
      await tmuxSendEnter(sock, session) // Enter in the same call is sometimes swallowed - a separate press
      await sleep(4000)
    } else if (action === 'press-enter') {
      await tmuxSendEnter(sock, session)
      await sleep(8000)
    }
  }
  return { ok: false, reason: 'max iterations reached without done', paneText: lastPane }
}

// Inject a hub/watch notice into a JUST RESUMED session so it knows its own
// process history (a resume is invisible from inside).
export async function injectNote(sock, session, note) {
  await tmuxSendLiteral(sock, session, note)
  await sleep(1500)
  await tmuxSendEnter(sock, session)
}

// Clear a stuck input box: a space + Enter CLEARS (does not send) - an
// empirically proven pattern from the remote-control fault.
export async function clearStuckInput(sock, session) {
  await tmuxSendLiteral(sock, session, ' ')
  await tmuxSendEnter(sock, session)
}

// Redeliver a stuck message (the watch's automatic path for a procedure once
// done by hand): a fresh busy check, clear the box, type the text again. A bus
// ping is resent verbatim (a fixed, contentless string); real text is marked
// so the recipient sees it came through the watch and not directly from a human.
export async function redeliverStuck(sock, session, text, isPing) {
  const pane = await capturePane(sock, session)
  // paneBusy, not a copy of its own: this was the THIRD copy of the same
  // condition, and they broke one at a time when a client release moved
  // 'esc to interrupt' into the permanent status line.
  if (pane == null || paneBusy(pane)) {
    return { ok: false, reason: 'the session is busy or the pane is unknown' }
  }
  await clearStuckInput(sock, session)
  await sleep(1500)
  const msg = isPing ? text : `[the watch: your message got stuck in the input box, verbatim:] ${text}`
  await tmuxSendLiteral(sock, session, msg)
  await sleep(1500)
  await tmuxSendEnter(sock, session)
  return { ok: true }
}
