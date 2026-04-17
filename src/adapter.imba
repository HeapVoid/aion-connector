# Adapter interface for coordinator CLIs. Phase 1 ships two:
#   - StubAdapter: always returns ready, no-ops everything. Used by integration tests.
#   - ClaudeCodeAdapter: wraps the real `claude` CLI. Added in Wave 5.
#
# Interface contract (every adapter implements):
#   installCoordinator({program, version}) -> Promise<void>
#   configure({model, credentials, persona, skills}) -> Promise<void>
#   start(), stop(), restart() -> Promise<void>
#   health() -> Promise<{ state: 'ready'|'starting'|'error', detail? }>
#   startAuth() -> Promise<{url} | null>
#   submitAuthCode({code}) -> Promise<{status: 'authorized'|'error', error?}>
#   writeSkills({persona, skills}) -> Promise<{persona: hash, skills: [{name, hash}]}>
#   readSkills() -> Promise<{persona: {hash, content}, skills: [{name, hash, content}]}>

import * as sync from './sync.imba'
import {mkdirSync} from 'fs'

export class StubAdapter
	home = null
	state = 'ready'
	configured = no

	def constructor h
		self.home = h
		mkdirSync(sync.coordinatorDir(h), { recursive: yes })

	def installCoordinator opts
		return

	def configure opts
		configured = yes
		if opts.persona !== undefined
			sync.writeFile(sync.personaPath(home), opts.persona)
		if opts.skills !== undefined
			sync.writeSkills(home, opts.skills)

	def start
		state = 'ready'

	def stop
		state = 'error'

	def restart
		state = 'ready'

	def health
		{ state: state }

	def startAuth
		null

	def submitAuthCode opts
		{ status: 'error', error: 'stub adapter does not authenticate' }

	def writeSkills opts
		const personaHash = sync.writeFile(sync.personaPath(home), opts.persona)
		const skillHashes = sync.writeSkills(home, opts.skills or [])
		{ persona: personaHash, skills: skillHashes }

	def readSkills
		const p = sync.readFile(sync.personaPath(home))
		const s = sync.listSkills(home)
		{ persona: p, skills: s }

const registry = { stub: StubAdapter }

export def registerAdapter name, cls
	registry[name] = cls

export def makeAdapter program, home
	const cls = registry[program]
	unless cls
		throw new Error("no adapter registered for program '{program}'")
	new cls(home)
