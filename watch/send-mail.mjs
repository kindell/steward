// watch/send-mail.mjs - the watch's alarm channel: one mail, sent as a service
// account impersonating the estate's alarm sender.
//
// NOTHING ESTATE-SPECIFIC LIVES HERE. The account file and the recipient are the
// estate's data: the orchestrator reads MAIL_ACCOUNT_FILE and ALERT_TO from the
// registry and passes them in. The estate's copy carried the account file's path
// as a literal - the name of one person's mailbox in the mechanism.
//
// THE ACCOUNT FILE is a key=value file (comments with #) naming a service
// account key file and the address to impersonate:
//   GMAIL_SA_KEY_FILE=~/.config/mail-accounts/<name>.json
//   GMAIL_IMPERSONATE=<address the mail is sent as>
// Its CONTENT never travels anywhere but into the signed request; the registry
// row names the file, never what is in it.
import { readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { createSign } from 'node:crypto'

const b64u = (s) => Buffer.from(s).toString('base64url')

export function loadAccount(accountFile) {
  if (!accountFile) throw new Error('send-mail: no account file given - the estate names it (MAIL_ACCOUNT_FILE)')
  const vars = Object.fromEntries(readFileSync(accountFile, 'utf-8').split('\n')
    .filter(l => l.includes('=') && !l.startsWith('#'))
    .map(l => [l.slice(0, l.indexOf('=')).trim(), l.slice(l.indexOf('=') + 1).trim()]))
  if (!vars.GMAIL_SA_KEY_FILE || !vars.GMAIL_IMPERSONATE) {
    throw new Error(`send-mail: ${accountFile} must name GMAIL_SA_KEY_FILE and GMAIL_IMPERSONATE`)
  }
  const key = JSON.parse(readFileSync(vars.GMAIL_SA_KEY_FILE.replace(/^~(?=\/)/, homedir()), 'utf-8'))
  return { key, impersonate: vars.GMAIL_IMPERSONATE }
}

// buildAssertion - the signed JWT the token endpoint exchanges for an access
// token. Pure apart from the signature: the tests pass a generated key and a
// fixed time, and read the claims back.
export function buildAssertion(key, impersonate, nowSec) {
  const header = b64u(JSON.stringify({ alg: 'RS256', typ: 'JWT' }))
  const claims = b64u(JSON.stringify({ iss: key.client_email, sub: impersonate, scope: 'https://www.googleapis.com/auth/gmail.send', aud: key.token_uri, iat: nowSec, exp: nowSec + 3600 }))
  const signer = createSign('RSA-SHA256'); signer.update(`${header}.${claims}`)
  return `${header}.${claims}.${signer.sign(key.private_key, 'base64url')}`
}

// buildMime - the raw message. The subject is base64-encoded as a whole so any
// character survives; the body is UTF-8, 8bit.
export function buildMime({ to, from, subject, text }) {
  const subj = `=?UTF-8?B?${Buffer.from(subject).toString('base64')}?=`
  return [`To: ${to}`, `From: ${from}`, `Subject: ${subj}`, 'MIME-Version: 1.0', 'Content-Type: text/plain; charset=UTF-8', 'Content-Transfer-Encoding: 8bit'].join('\r\n') + '\r\n\r\n' + text
}

// sendMail({ to, subject, text }, { accountFile, fetch }) -> the sent message's id.
// `fetch` is injectable so the tests never reach the network; a failed token or
// send is an error naming the step and the status, never a silent zero.
export async function sendMail({ to, subject, text }, { accountFile, fetch: fetchImpl = globalThis.fetch, now = () => Date.now() } = {}) {
  if (!to) throw new Error('send-mail: no recipient given - the estate names it (ALERT_TO)')
  const { key, impersonate } = loadAccount(accountFile)
  const assertion = buildAssertion(key, impersonate, Math.floor(now() / 1000))
  const tok = await fetchImpl(key.token_uri, { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion }), signal: AbortSignal.timeout(20000) })
  if (!tok.ok) throw new Error(`send-mail: token ${tok.status}`)
  const { access_token } = await tok.json()
  const mime = buildMime({ to, from: impersonate, subject, text })
  const res = await fetchImpl('https://gmail.googleapis.com/gmail/v1/users/me/messages/send', { method: 'POST', headers: { Authorization: `Bearer ${access_token}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ raw: Buffer.from(mime, 'utf-8').toString('base64url') }), signal: AbortSignal.timeout(20000) })
  if (!res.ok) throw new Error(`send-mail: send ${res.status}`)
  return (await res.json()).id
}
