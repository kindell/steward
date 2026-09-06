// watch/test/send-mail.test.mjs - the alarm channel, without the network.
//
// The account file and the recipient are the estate's data and arrive as
// arguments; fetch is injected. What is proven: the account file is read and
// refused when incomplete, the assertion carries the right claims and verifies
// against the key it was signed with, the MIME is addressed and encoded
// correctly, and a failed step is an error that names the step.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { generateKeyPairSync, createVerify } from 'node:crypto'
import { loadAccount, buildAssertion, buildMime, sendMail } from '../send-mail.mjs'

const dir = mkdtempSync(join(tmpdir(), 'send-mail-'))
const { privateKey, publicKey } = generateKeyPairSync('rsa', { modulusLength: 2048 })
const keyFile = join(dir, 'sa.json')
writeFileSync(keyFile, JSON.stringify({
  client_email: 'watch@example.invalid',
  token_uri: 'https://oauth.example.invalid/token',
  private_key: privateKey.export({ type: 'pkcs8', format: 'pem' }),
}))
const accountFile = join(dir, 'alerts.env')
writeFileSync(accountFile, `# the estate's alarm account\nGMAIL_SA_KEY_FILE=${keyFile}\nGMAIL_IMPERSONATE=alerts@example.invalid\n`)

test('loadAccount: reads the key file and the impersonated address', () => {
  const a = loadAccount(accountFile)
  assert.equal(a.impersonate, 'alerts@example.invalid')
  assert.equal(a.key.client_email, 'watch@example.invalid')
})

test('loadAccount: refuses without an account file, and an incomplete one', () => {
  assert.throws(() => loadAccount(''), /MAIL_ACCOUNT_FILE/)
  const half = join(dir, 'half.env'); writeFileSync(half, 'GMAIL_IMPERSONATE=x@example.invalid\n')
  assert.throws(() => loadAccount(half), /GMAIL_SA_KEY_FILE/)
})

test('buildAssertion: the claims name the account, the recipient of trust and the hour', () => {
  const { key } = loadAccount(accountFile)
  const jwt = buildAssertion(key, 'alerts@example.invalid', 1_700_000_000)
  const [h, c, sig] = jwt.split('.')
  assert.deepEqual(JSON.parse(Buffer.from(h, 'base64url')), { alg: 'RS256', typ: 'JWT' })
  const claims = JSON.parse(Buffer.from(c, 'base64url'))
  assert.equal(claims.iss, 'watch@example.invalid')
  assert.equal(claims.sub, 'alerts@example.invalid')
  assert.equal(claims.aud, 'https://oauth.example.invalid/token')
  assert.equal(claims.exp - claims.iat, 3600)
  assert.match(claims.scope, /gmail\.send$/)
  // and it verifies against the key it was signed with
  const v = createVerify('RSA-SHA256'); v.update(`${h}.${c}`)
  assert.equal(v.verify(publicKey, Buffer.from(sig, 'base64url')), true)
})

test('buildMime: addressed, subject encoded whole, body 8bit UTF-8', () => {
  const m = buildMime({ to: 'human@example.invalid', from: 'alerts@example.invalid', subject: 'hub-one watch: alpha has no process', text: 'line one\nline two' })
  assert.match(m, /^To: human@example\.invalid\r\n/)
  assert.match(m, /\r\nFrom: alerts@example\.invalid\r\n/)
  const subj = m.match(/\r\nSubject: =\?UTF-8\?B\?([A-Za-z0-9+/=]+)\?=\r\n/)
  assert.ok(subj, 'the subject is base64-encoded as a whole')
  assert.equal(Buffer.from(subj[1], 'base64').toString(), 'hub-one watch: alpha has no process')
  assert.match(m, /Content-Type: text\/plain; charset=UTF-8\r\n/)
  assert.ok(m.endsWith('\r\n\r\nline one\nline two'))
})

test('sendMail: token then send, both through the injected fetch; returns the message id', async () => {
  const calls = []
  const fetchImpl = async (url, init) => {
    calls.push({ url, init })
    if (url.endsWith('/token')) return { ok: true, status: 200, json: async () => ({ access_token: 'tok-1' }) }
    return { ok: true, status: 200, json: async () => ({ id: 'msg-42' }) }
  }
  const id = await sendMail({ to: 'human@example.invalid', subject: 's', text: 't' }, { accountFile, fetch: fetchImpl, now: () => 1_700_000_000_000 })
  assert.equal(id, 'msg-42')
  assert.equal(calls.length, 2)
  assert.equal(calls[0].url, 'https://oauth.example.invalid/token')
  assert.match(String(calls[0].init.body), /grant_type=urn/)
  assert.equal(calls[1].init.headers.Authorization, 'Bearer tok-1')
  const raw = JSON.parse(calls[1].init.body).raw
  assert.match(Buffer.from(raw, 'base64url').toString(), /^To: human@example\.invalid/)
})

test('sendMail: a failed token or send is an error naming the step and the status', async () => {
  const bad = (status) => async (url) => ({ ok: false, status, json: async () => ({}) })
  await assert.rejects(sendMail({ to: 'h@example.invalid', subject: 's', text: 't' }, { accountFile, fetch: bad(401) }), /token 401/)
  const sendFails = async (url) => url.endsWith('/token') ? { ok: true, status: 200, json: async () => ({ access_token: 'x' }) } : { ok: false, status: 500 }
  await assert.rejects(sendMail({ to: 'h@example.invalid', subject: 's', text: 't' }, { accountFile, fetch: sendFails }), /send 500/)
})

test('sendMail: refuses without a recipient - the estate names it', async () => {
  await assert.rejects(sendMail({ to: '', subject: 's', text: 't' }, { accountFile, fetch: async () => ({ ok: true }) }), /ALERT_TO/)
})
