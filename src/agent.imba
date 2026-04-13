import {VERSION} from './protocol.imba'
import {log, error as err, exec} from './utils.imba'
import {spawn} from 'child_process'
import {writeFileSync, existsSync, readFileSync} from 'fs'
import {dirname, resolve} from 'path'
import {fileURLToPath} from 'url'

const __dir = dirname(fileURLToPath(import.meta.url))
const MCP_SERVER = resolve(__dir, 'mcp-server.js')

# If no NDJSON output for this long, auto-complete (fallback for long-running tools like bun dev)
const IDLE_TIMEOUT = 30 * 1000 # 30 seconds

const runningProcs = new Map!

export def stopAgent sid
	log "stopping agent session: {sid}"
	const entry = runningProcs.get(sid)
	if entry
		try entry.proc.kill!
		runningProcs.delete(sid)

export def shutdownAllAgents
	if runningProcs.size == 0
		return
	log "shutting down {runningProcs.size} running agent(s)..."
	const promises = []
	for [sid, entry] of runningProcs
		try entry.proc.kill!
		if entry.payload
			promises.push(sendCallback(entry.payload, "error", sessionId: sid, error: "Connector shutting down"))
		runningProcs.delete(sid)
	try await Promise.allSettled(promises)
	log "all agent sessions closed"

def sendCallback payload, action, data
	const cb = payload.callback
	return unless cb
	const endpoints = { output: "agent-stream", complete: "agent-complete", error: "agent-error" }
	const ep = endpoints[action]
	return unless ep
	data.token = payload.token or ""
	try
		await globalThis.fetch "{cb}/internal/{ep}",
			method: "POST"
			headers: { "content-type": "application/json" }
			body: JSON.stringify(data)
	catch e
		err "shutdown callback ({action}): {e.message}"

def writeMcpTo dir, payload, sid
	const mcpPath = resolve(dir, '.mcp.json')
	let config = { mcpServers: {} }

	if existsSync(mcpPath)
		try
			config = JSON.parse(readFileSync(mcpPath, 'utf8'))
			if !config.mcpServers or typeof config.mcpServers != 'object'
				config.mcpServers = {}

	config.mcpServers.aion = {
		type: "stdio"
		command: "node"
		args: [MCP_SERVER]
		env: {
			AION_CALLBACK: payload.callback or ""
			AION_TOKEN: payload.token or ""
			AION_SESSION_ID: sid
		}
		instructions: "AION platform tools. Use run_background to start long-running processes (dev servers, watchers) — NEVER use Bash for these. Use check_background/stop_background to manage them. Use display_set to show URLs on the team display panel, display_clear to clear it."
	}

	writeFileSync(mcpPath, JSON.stringify(config, null, 2))
	log "mcp config written to {mcpPath}"

def enableMcpInClaude dir
	# Claude Code requires MCP servers from .mcp.json to be explicitly approved
	# in ~/.claude.json (enabledMcpjsonServers). In headless mode (acpx) the
	# trust dialog never shows, so we add "aion" programmatically.
	const home = process.env.HOME or process.env.USERPROFILE or "/root"
	const claudeConfig = resolve(home, '.claude.json')
	try
		let config = {}
		if existsSync(claudeConfig)
			config = JSON.parse(readFileSync(claudeConfig, 'utf8'))
		config.projects ||= {}
		config.projects[dir] ||= {}
		const enabled = config.projects[dir].enabledMcpjsonServers ||= []
		unless enabled.includes('aion')
			enabled.push('aion')
			writeFileSync(claudeConfig, JSON.stringify(config, null, 2))
			log "enabled aion MCP server in {claudeConfig} for {dir}"
	catch e
		err "failed to update claude config: {e.message}"

def setupMcp dir, payload, sid
	writeMcpTo(dir, payload, sid)
	enableMcpInClaude(dir)

export class Agent
	#connector

	def constructor connector
		#connector = connector

	def compose payload
		let parts = []
		if payload.system
			parts.push("<system>\n{payload.system}\n</system>")
		if payload.memory
			parts.push("<project-notes>\n{payload.memory}\n</project-notes>")
		if payload.instructions
			parts.push("<chat-instructions>\n{payload.instructions}\n</chat-instructions>")
		if payload.history and payload.history.length
			let lines = []
			for msg in payload.history
				const role = msg.role or msg.source or 'user'
				lines.push("{role}: {msg.text}")
			parts.push("<recent-messages>\n{lines.join('\n')}\n</recent-messages>")
		if parts.length
			return "{parts.join('\n\n')}\n\n{payload.prompt}"
		payload.prompt

	def invoke payload, ws
		const dir = ws.dir
		const name = payload.agent
		const sid = payload.session or "default"

		unless name
			err "no agent specified in payload"
			await send(payload, "error", sessionId: sid, error: "no agent specified")
			return

		setupMcp(dir, payload, sid)
		try
			log "invoking {name} (session {sid}) in {dir}"

			# ensure session exists (agent name before subcommand)
			const ensure = await exec([
				"acpx", "--cwd", dir, name, "sessions", "ensure", "--name", sid
			], cwd: dir)
			if ensure.exitCode != 0
				log "ensure session: {ensure.stderr.slice(0, 200)}"

			# compose prompt with system context
			const prompt = compose(payload)

			# run prompt via acpx with NDJSON output
			const args = ["acpx", "--cwd", dir, "--format", "json", "--approve-all"]
			if payload.model
				args.push("--model", payload.model)
			args.push(name, "-s", sid, prompt)

			log "cmd: {args.join(' ')}"

			let result = null
			let attempts = 0
			const MAX_RETRIES = 2

			while attempts <= MAX_RETRIES
				result = await runProc(args, dir, sid, payload)
				attempts++

				# Successfully completed with content during streaming
				break if result.completed and result.buf.trim!.length > 0

				# Decide if we should retry
				const needsReconnect = !result.completed and (result.code == 5 or (result.code != 0 and result.stderr.includes("needs reconnect")))
				const emptyResponse = result.completed and result.buf.trim!.length == 0

				if (needsReconnect or emptyResponse) and attempts <= MAX_RETRIES
					const reason = needsReconnect ? "reconnect needed (exit {result.code})" : "empty response"
					log "session {sid}: {reason}, retry {attempts}/{MAX_RETRIES}"
					continue

				break

			# Send final result if not already sent with content during streaming
			if result.completed and result.buf.trim!.length > 0
				# Already sent during streaming via finish()
				log "session {sid} done ({result.buf.length} chars)"
			elif result.completed and result.buf.trim!.length == 0
				err "session {sid}: empty response after {attempts} attempt(s)"
				await send(payload, "error", sessionId: sid, error: "Agent returned an empty response after {attempts} attempt(s)")
			elif result.code != 0
				err "acpx exited {result.code}: {result.stderr.slice(0, 300)}"
				await send(payload, "error", sessionId: sid, error: result.stderr.slice(0, 500))
			else
				const changed = dir ? await delta(dir) : []
				await send(payload, "complete", sessionId: sid, summary: result.buf, changed: changed)
				log "session {sid} complete ({result.buf.length} chars)"
		catch e
			err "invoke crashed: {e.message}"
			runningProcs.delete(sid)
			await send(payload, "error", sessionId: sid, error: "connector error: {e.message}")

	def runProc args, dir, sid, payload
		const proc = spawn(args[0], args.slice(1), {
			cwd: dir
			stdio: ['pipe', 'pipe', 'pipe']
		})
		runningProcs.set(sid, { proc, payload })

		let buf = ""
		let partial = ""
		let stderr = ""
		let completed = no
		let idleTimer = null

		const finish = do
			return if completed
			completed = yes
			if idleTimer
				clearTimeout(idleTimer)
			if buf.trim!.length == 0
				log "session {sid} end_turn with empty response — skipping send"
				return
			log "session {sid} complete — sending result ({buf.length} chars)"
			const changed = dir ? await delta(dir) : []
			await send(payload, "complete", sessionId: sid, summary: buf, changed: changed)

		const resetIdle = do
			if idleTimer
				clearTimeout(idleTimer)
			idleTimer = setTimeout(&, IDLE_TIMEOUT) do
				if !completed and buf.length > 0
					log "session {sid} idle {IDLE_TIMEOUT / 1000}s — auto-completing"
					finish!

		proc.stdout.on('data', do(chunk)
			resetIdle!
			partial += chunk.toString!
			const lines = partial.split("\n")
			partial = lines.pop! or ""
			for line in lines
				continue unless line.trim!
				try
					const event = JSON.parse(line)
					if isTurnComplete(event)
						finish!
						continue
					const text = extract(event)
					buf += text
					if text
						send(payload, "output", sessionId: sid, text: text)
				catch
					buf += line
		)

		proc.stderr.on('data', do(chunk)
			resetIdle!
			stderr += chunk.toString!
		)

		# Start idle timer
		resetIdle!

		const code = await new Promise do(ok)
			proc.on('close', do(c) ok(c))
		if idleTimer
			clearTimeout(idleTimer)
		runningProcs.delete(sid)

		if completed
			log "acpx exited {code} after completion (session {sid})"

		{ buf, stderr, code, completed }

	def isTurnComplete event
		# JSON-RPC result with stopReason = agent finished responding
		event..result..stopReason == "end_turn"

	def extract event
		# extract readable text from JSON-RPC event
		const params = event..params
		const update = params..update
		# agent_message_chunk — streaming text from agent
		if update and update.sessionUpdate == "agent_message_chunk"
			return update..content..text or ""
		# simple text events (fallback for other agents)
		if event.type == "text_delta" or event.type == "text"
			return event.delta or event.text or ""
		if event.type == "agent_message" and event.content
			return event.content
		""

	def send payload, action, data, retries = 2
		const cb = payload.callback
		return unless cb
		const endpoints = { output: "agent-stream", complete: "agent-complete", error: "agent-error" }
		const ep = endpoints[action]
		return unless ep
		data.token = payload.token or ""
		const body = JSON.stringify(data)
		let attempt = 0
		while attempt <= retries
			try
				const res = await globalThis.fetch "{cb}/internal/{ep}",
					method: "POST"
					headers: { "content-type": "application/json" }
					body: body
				unless res.ok
					const txt = await res.text!
					err "callback ({action}): HTTP {res.status} — {txt.slice(0, 200)}"
				return
			catch e
				attempt++
				err "callback ({action}): {e.message} (attempt {attempt}/{retries + 1})"
				if attempt <= retries
					await new Promise do(ok) setTimeout(ok, 1000 * attempt)

	def delta dir
		try
			const result = await exec(["git", "diff", "--name-status"], cwd: dir)
			result.stdout.trim!.split("\n").filter(Boolean).map do(line)
				const parts = line.split("\t")
				{ status: parts[0], path: parts[1] }
		catch
			[]
