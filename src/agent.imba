import {VERSION} from './protocol.imba'
import {log, error as err} from './utils.imba'

export class Agent
	#connector
	#decoder = new TextDecoder!

	def constructor connector
		#connector = connector

	def invoke payload, ws
		const dir = ws.repos.resolve! or ws.dir
		const name = payload.agent
		const sid = payload.session or "default"

		unless name
			err "no agent specified in payload"
			await send(payload, "error", session: sid, error: "no agent specified")
			return

		log "invoking {name} (session {sid}) in {dir}"

		# ensure session exists (agent name before subcommand)
		const ensure = Bun.spawn [
			"acpx", name, "sessions", "ensure", "--name", sid
		], cwd: dir, stdout: "pipe", stderr: "pipe"
		await ensure.exited
		if ensure.exitCode != 0
			const eout = await new Response(ensure.stderr).text!
			log "ensure session: {eout.slice(0, 200)}"

		# run prompt via acpx with NDJSON output
		# --format is global (before agent), -s is agent-specific (after agent)
		const args = ["acpx", "--format", "json"]
		if payload.model
			args.push("--model", payload.model)
		args.push(name, "-s", sid, payload.prompt)

		log "cmd: {args.join(' ')}"

		const proc = Bun.spawn args,
			cwd: dir
			stdout: "pipe"
			stderr: "pipe"

		let buf = ""
		let partial = ""
		const reader = proc.stdout.getReader!

		while yes
			const {done, value} = await reader.read!
			break if done
			partial += #decoder.decode(value)
			# parse complete NDJSON lines
			const lines = partial.split("\n")
			partial = lines.pop! or ""
			for line in lines
				continue unless line.trim!
				try
					const event = JSON.parse(line)
					buf += extract(event)
					await send(payload, "output", session: sid, text: line)
				catch
					buf += line

		await proc.exited

		if proc.exitCode != 0
			const stderr = await new Response(proc.stderr).text!
			err "acpx exited {proc.exitCode}: {stderr.slice(0, 300)}"
			await send(payload, "error", session: sid, error: stderr.slice(0, 500))
		else
			const changed = dir ? await delta(dir) : []
			await send(payload, "complete", session: sid, summary: buf, changed: changed)
			log "session {sid} complete ({buf.length} chars)"

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

	def send payload, action, data
		const cb = payload.callback
		return unless cb
		try
			await globalThis.fetch "{cb}/agents/channel",
				method: "POST"
				headers: { "content-type": "application/json" }
				body: JSON.stringify
					v: VERSION
					action: action
					token: payload.token or ""
					payload: data
		catch e
			err "callback ({action}): {e.message}"

	def delta dir
		try
			const proc = Bun.spawn ["git", "diff", "--name-status"],
				cwd: dir
				stdout: "pipe"
			const out = await new Response(proc.stdout).text!
			await proc.exited
			out.trim!.split("\n").filter(Boolean).map do(line)
				const parts = line.split("\t")
				{ status: parts[0], path: parts[1] }
		catch
			[]
