import {VERSION} from './protocol.imba'
import {log, error as err, exec} from './utils.imba'
import {spawn} from 'child_process'
import {writeFileSync, existsSync, readFileSync} from 'fs'
import {dirname, resolve} from 'path'
import {fileURLToPath} from 'url'

const __dir = dirname(fileURLToPath(import.meta.url))
const MCP_SERVER = resolve(__dir, 'mcp-server.js')

const runningProcs = new Map!

export def stopAgent sid
	log "stopping agent session: {sid}"
	const proc = runningProcs.get(sid)
	if proc
		try proc.kill!
		runningProcs.delete(sid)

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
	}

	writeFileSync(mcpPath, JSON.stringify(config, null, 2))
	log "mcp config written to {mcpPath}"

def setupMcp dir, payload, sid
	writeMcpTo(dir, payload, sid)

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
			const args = ["acpx", "--cwd", dir, "--format", "json"]
			if payload.model
				args.push("--model", payload.model)
			args.push(name, "-s", sid, prompt)

			log "cmd: {args.join(' ')}"

			const proc = spawn(args[0], args.slice(1), {
				cwd: dir
				stdio: ['pipe', 'pipe', 'pipe']
			})
			runningProcs.set(sid, proc)

			let buf = ""
			let partial = ""
			let stderr = ""

			proc.stdout.on('data', do(chunk)
				partial += chunk.toString!
				const lines = partial.split("\n")
				partial = lines.pop! or ""
				for line in lines
					continue unless line.trim!
					try
						const event = JSON.parse(line)
						const text = extract(event)
						buf += text
						if text
							send(payload, "output", sessionId: sid, text: text)
					catch
						buf += line
			)

			proc.stderr.on('data', do(chunk) stderr += chunk.toString!)

			const code = await new Promise do(ok)
				proc.on('close', do(c) ok(c))
			runningProcs.delete(sid)

			if code == 5
				# Exit code 5 = "agent needs reconnect" — auto-retry once
				log "acpx exit 5 (reconnect needed), retrying session {sid}"
				buf = ""
				partial = ""
				stderr = ""
				const proc2 = spawn(args[0], args.slice(1), {
					cwd: dir
					stdio: ['pipe', 'pipe', 'pipe']
				})
				runningProcs.set(sid, proc2)
				proc2.stdout.on('data', do(chunk)
					partial += chunk.toString!
					const lines = partial.split("\n")
					partial = lines.pop! or ""
					for line in lines
						continue unless line.trim!
						try
							const event = JSON.parse(line)
							const text = extract(event)
							buf += text
							if text
								send(payload, "output", sessionId: sid, text: text)
						catch
							buf += line
				)
				proc2.stderr.on('data', do(chunk) stderr += chunk.toString!)
				const code2 = await new Promise do(ok)
					proc2.on('close', do(c) ok(c))
				runningProcs.delete(sid)
				if code2 != 0
					err "acpx retry exited {code2}: {stderr.slice(0, 300)}"
					await send(payload, "error", sessionId: sid, error: stderr.slice(0, 500))
				else
					const changed = dir ? await delta(dir) : []
					await send(payload, "complete", sessionId: sid, summary: buf, changed: changed)
					log "session {sid} complete after retry ({buf.length} chars)"
			elif code != 0
				err "acpx exited {code}: {stderr.slice(0, 300)}"
				await send(payload, "error", sessionId: sid, error: stderr.slice(0, 500))
			else
				const changed = dir ? await delta(dir) : []
				await send(payload, "complete", sessionId: sid, summary: buf, changed: changed)
				log "session {sid} complete ({buf.length} chars)"
		catch e
			err "invoke crashed: {e.message}"
			runningProcs.delete(sid)
			await send(payload, "error", sessionId: sid, error: "connector error: {e.message}")

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
