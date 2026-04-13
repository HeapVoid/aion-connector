import {VERSION} from './protocol.imba'
import {log, error as err, exec} from './utils.imba'
import {spawn} from 'child_process'

const runningProcs = new Map!

export def stopAgent sid
	log "stopping agent session: {sid}"
	const proc = runningProcs.get(sid)
	if proc
		try proc.kill!
		runningProcs.delete(sid)

export class Agent
	#connector

	def constructor connector
		#connector = connector

	def invoke payload, ws
		const dir = ws.repos.resolve! or ws.dir
		const name = payload.agent
		const sid = payload.session or "default"

		unless name
			err "no agent specified in payload"
			await send(payload, "error", sessionId: sid, error: "no agent specified")
			return

		try
			log "invoking {name} (session {sid}) in {dir}"

			# ensure session exists (agent name before subcommand)
			const ensure = await exec([
				"acpx", name, "sessions", "ensure", "--name", sid
			], cwd: dir)
			if ensure.exitCode != 0
				log "ensure session: {ensure.stderr.slice(0, 200)}"

			# run prompt via acpx with NDJSON output
			const args = ["acpx", "--format", "json"]
			if payload.model
				args.push("--model", payload.model)
			args.push(name, "-s", sid, payload.prompt)

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
						buf += extract(event)
						send(payload, "output", sessionId: sid, text: line)
					catch
						buf += line
			)

			proc.stderr.on('data', do(chunk) stderr += chunk.toString!)

			const code = await new Promise do(ok)
				proc.on('close', do(c) ok(c))
			runningProcs.delete(sid)

			if code != 0
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
