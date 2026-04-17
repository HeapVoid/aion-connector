import * as utils from './utils.imba'
import * as sync from './sync.imba'
import * as fs from 'fs'
import * as path from 'path'

# Wraps the real `claude` CLI. claude-code is invoked per-turn via acpx, not as a daemon —
# so start/stop/restart are mostly no-ops; health() just probes the binary.
export class ClaudeCodeAdapter
	home = null
	installed = no
	authorized = no
	authProc = null

	def constructor h
		self.home = h
		fs.mkdirSync(sync.coordinatorDir(h), { recursive: yes })

	# Idempotent: install @anthropic-ai/claude-code into the user's npm prefix, or verify present.
	def installCoordinator opts
		const which = await utils.exec(['which', 'claude'])
		if which.exitCode == 0
			installed = yes
			return
		const version = opts.version or 'latest'
		utils.log "installing @anthropic-ai/claude-code@{version}..."
		const inst = await utils.exec(['npm', 'install', '-g', "@anthropic-ai/claude-code@{version}"])
		if inst.exitCode != 0
			throw new Error("npm install failed: {inst.stderr}")
		installed = yes

	def configure opts
		if opts.persona !== undefined
			sync.writeFile(sync.personaPath(home), opts.persona)
		if opts.skills !== undefined
			sync.writeSkills(home, opts.skills)
		if opts.credentials !== undefined and opts.credentials.api_key
			const envPath = path.join(sync.coordinatorDir(home), 'credentials.env')
			fs.writeFileSync(envPath, "ANTHROPIC_API_KEY={opts.credentials.api_key}\n")
			fs.chmodSync(envPath, 0o600)
		const cfg = { program: 'claude-code', model: opts.model }
		fs.writeFileSync(path.join(sync.coordinatorDir(home), 'config.json'), JSON.stringify(cfg, null, 2))

	def start
		return

	def stop
		return

	def restart
		return

	def health
		unless installed
			const which = await utils.exec(['which', 'claude'])
			installed = which.exitCode == 0
		unless installed
			return { state: 'error', detail: 'claude binary not found' }
		{ state: 'ready' }

	def startAuth
		throw new Error("startAuth not implemented yet")

	def submitAuthCode opts
		throw new Error("submitAuthCode not implemented yet")

	def writeSkills opts
		const personaHash = sync.writeFile(sync.personaPath(home), opts.persona)
		const skillHashes = sync.writeSkills(home, opts.skills or [])
		{ persona: personaHash, skills: skillHashes }

	def readSkills
		const p = sync.readFile(sync.personaPath(home))
		{ persona: p, skills: sync.listSkills(home) }
