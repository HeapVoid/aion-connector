import * as utils from './utils.imba'
import * as sync from './sync.imba'
import * as fs from 'fs'
import * as path from 'path'
import * as cp from 'child_process'

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
		if opts.credentials and opts.credentials.api_key
			const envPath = path.join(sync.coordinatorDir(home), 'credentials.env')
			fs.writeFileSync(envPath, "ANTHROPIC_API_KEY={opts.credentials.api_key}\n")
			fs.chmodSync(envPath, 0o600)
		# Partial updates (e.g. persona-only) must not wipe the model. Read current
		# config and merge: explicit opts.model wins, otherwise keep what's on disk.
		const configPath = path.join(sync.coordinatorDir(home), 'config.json')
		let currentModel = null
		if fs.existsSync(configPath)
			try
				const cur = JSON.parse(fs.readFileSync(configPath, 'utf8'))
				currentModel = cur.model
			catch e
				currentModel = null
		const model = opts.model !== undefined ? opts.model : currentModel
		const cfg = { program: 'claude-code', model: model }
		fs.writeFileSync(configPath, JSON.stringify(cfg, null, 2))

	def start
		return

	def stop
		return

	def restart
		return

	def health
		unless installed
			try
				const which = await utils.exec(['which', 'claude'])
				installed = which.exitCode == 0
			catch e
				# `which` itself may be unresolvable (eg. tests with a
				# mangled PATH, stripped container image). Treat as
				# claude_missing rather than propagating to the caller.
				installed = no
		unless installed
			return { state: 'error', detail: 'claude_missing' }

		# Peek at credentials.json without spawning a subprocess or
		# hitting the network. Health probes run on every heartbeat
		# (~30s cadence), so this must stay cheap.
		#
		# Threshold: refuse if expires_at < now+60s — treat
		# "about to expire" as already-expired so the UI CTA lights
		# up before the first call-time failure.
		const credsPath = path.join(self.home, '.claude', 'credentials.json')
		unless fs.existsSync(credsPath)
			return { state: 'error', detail: 'not_authorized' }

		try
			const raw = fs.readFileSync(credsPath, 'utf8')
			const creds = JSON.parse(raw)
			if creds.expires_at and creds.expires_at < Date.now! + 60_000
				return { state: 'error', detail: 'not_authorized' }
		catch e
			return { state: 'error', detail: 'creds_corrupt' }

		{ state: 'ready' }

	def startAuth
		const env = Object.assign({}, process.env, { HOME: self.home })
		const proc = cp.spawn('claude', ['setup-token'], { stdio: ['pipe', 'pipe', 'pipe'], env: env })
		self.authProc = proc
		let stdout = ''
		return new Promise do(ok, ko)
			let resolved = no
			const urlRegex = /(https?:\/\/\S+)/
			proc.stdout.on 'data', do(chunk)
				stdout += chunk.toString!
				const m = stdout.match(urlRegex)
				if m and !resolved
					resolved = yes
					ok({ url: m[1] })
			proc.on 'exit', do(code)
				unless resolved
					resolved = yes
					ko(new Error("claude setup-token exited {code} before URL appeared"))

	def submitAuthCode opts
		unless self.authProc
			return { status: 'error', error: 'no auth in progress — call startAuth first' }
		const proc = self.authProc
		const self2 = self
		proc.stdin.write("{opts.code}\n")
		proc.stdin.end!
		return new Promise do(ok)
			proc.on 'exit', do(ec)
				self2.authProc = null
				if ec == 0
					self2.authorized = yes
					ok({ status: 'authorized' })
				else
					ok({ status: 'error', error: "claude setup-token exited {ec}" })

	def writeSkills opts
		const personaHash = sync.writeFile(sync.personaPath(home), opts.persona, opts.expected_persona_hash)
		const skillHashes = sync.writeSkills(home, opts.skills or [])
		{ persona: personaHash, skills: skillHashes }

	def readSkills
		const p = sync.readFile(sync.personaPath(home))
		{ persona: p, skills: sync.listSkills(home) }
