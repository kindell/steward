// watch/estate.mjs - the watch's view of the registry, through the ONE reader.
//
// Node cannot source lib/registry.sh, and the estate's watch answered that with
// a parser of its own - a second reader of the same rows, with its own defaults.
// This module asks the bash bridge (watch/bin/registry-dump) instead: it
// sources the registry library, answers, and prints JSON. What the watch knows
// about a session, a host or the estate is exactly what the registry says.
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const exec = promisify(execFile)
const DUMP = join(dirname(fileURLToPath(import.meta.url)), 'bin', 'registry-dump')

async function dump(what) {
  const { stdout, stderr } = await exec('bash', [DUMP, what], { maxBuffer: 8 * 1024 * 1024 })
  // Ordinary malformed rows are named and skipped. Invalid account identity
  // makes the bridge fail, so the watch never accepts an incomplete fleet.
  for (const line of String(stderr).split('\n')) if (line.trim()) console.error(line)
  return stdout
}

// listSessions -> [{name, id, slug, rcLabel, label, host, owner}]
export async function listSessions() {
  const out = await dump('sessions')
  return out.split('\n').filter(l => l.trim()).map(l => JSON.parse(l))
}

// hostOperators -> {<host>: <OPERATOR>}
export async function hostOperators() {
  return JSON.parse((await dump('hosts')).trim() || '{}')
}

// estate -> {hubSession, hubHost, tmuxSocket, pingMsg, stateDirName,
//            pausedDirName, mailAccountFile, alertTo, jobStatusCmd, hostStatusCmd}
// The required keys refuse in the bridge (the process exits 78 with the
// registry's own explanation); the optional ones arrive as ''.
export async function estate() {
  return JSON.parse((await dump('estate')).trim())
}
