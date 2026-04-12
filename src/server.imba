import {VERSION} from './protocol.imba'
import {log} from './utils.imba'

# Try to load node-pty for proper PTY terminal (colors, job control, readline)
# Falls back to Bun.spawn pipe if not available
let pty = null
try
	pty = require('node-pty')
	log "node-pty loaded — full PTY terminal available"
catch
	log "node-pty not available — using pipe-based terminal (no job control)"

export class Server
	#connector
	#server = null
	#terminals = {}
	#httpTerminals = {}  # HTTP-based terminal sessions: {id: {proc, buffer, alive}}

	def constructor connector
		#connector = connector

	def start
		const srv = this
		#server = Bun.serve
			port: #connector.port
			hostname: #connector.host
			fetch: do(req) srv.handle(req)
			websocket:
				open: do(ws) srv.wsOpen(ws)
				message: do(ws, msg) srv.wsMessage(ws, msg)
				close: do(ws) srv.wsClose(ws)
		log "listening on {#connector.host}:{#connector.port}"

	def stop
		# Kill all terminals (WS)
		for own id, t of #terminals
			t.proc..kill!
		#terminals = {}
		# Kill all HTTP terminal sessions
		for own id, s of #httpTerminals
			try s.proc.kill!
		#httpTerminals = {}
		#server..stop!

	def handle req
		# WebSocket upgrade for terminal
		if req.headers.get("upgrade") == "websocket"
			return handleUpgrade(req)

		unless req.method == "POST"
			return respond({ error: "POST only" }, 405)

		let msg
		try
			msg = await req.json!
		catch
			return respond({ error: "invalid json" }, 400)

		if msg.v and msg.v > VERSION
			return respond({ error: "version", min: msg.v }, 400)

		# Authenticate token → get project id
		const pid = #connector.auth(msg.token)
		unless pid
			return respond({ error: "unauthorized" }, 403)

		# Verify payload.project matches token's project
		const p = msg.payload or {}
		if p.project and p.project != pid
			return respond({ error: "token/project mismatch" }, 403)

		# Inject correct project id
		p.project = pid

		switch msg.action
			when "invoke"
				#connector.invoke(p)
				return respond({ ok: yes })
			when "agents"
				return respond({ agents: #connector.agents(pid) })
			when "repos.sync"
				const ws = #connector.workspace(pid)
				if ws
					await ws.repos.sync(p.repos or [])
				return respond({ ok: yes })
			when "files.tree"
				const files = #connector.filesFor(pid)
				return respond(files ? await files.tree(p) : { error: "no workspace" })
			when "files.read"
				const files = #connector.filesFor(pid)
				return respond(files ? await files.read(p) : { error: "no workspace" })
			when "git.status"
				const files = #connector.filesFor(pid)
				return respond(files ? await files.status(p) : { error: "no workspace" })
			when "git.diff"
				const files = #connector.filesFor(pid)
				return respond(files ? await files.diff(p) : { error: "no workspace" })
			when "workspaces"
				const ws = #connector.workspace(pid)
				return respond({ list: ws ? ws.repos.list! : [] })
			when "terminal.spawn"
				return respond(termSpawn(pid))
			when "terminal.input"
				return respond(termInput(p.sessionId, p.data))
			when "terminal.output"
				return respond(termOutput(p.sessionId))
			when "terminal.resize"
				return respond(termResize(p.sessionId, p.cols, p.rows))
			when "terminal.close"
				return respond(termClose(p.sessionId))
			when "ping"
				return respond({ ok: yes, v: VERSION })
			else
				return respond({ error: "unknown action" }, 400)

	# --- WebSocket terminal ---

	def handleUpgrade req
		const url = new URL(req.url)
		const token = url.searchParams.get("token")
		const pid = #connector.auth(token)
		unless pid
			return respond({ error: "unauthorized" }, 403)
		const success = #server.upgrade(req, { data: { pid } })
		if success
			return undefined
		return respond({ error: "upgrade failed" }, 400)

	def wsOpen ws
		const pid = ws.data.pid
		const proj = #connector.project(pid)
		unless proj
			ws.close!
			return
		const id = Math.random!.toString(36).slice(2)
		ws.data.termId = id
		log "terminal opened: {id} (project {pid})"

		if pty
			# Full PTY via node-pty — colors, job control, readline
			const shell = process.env.SHELL or 'bash'
			const term = pty.spawn(shell, [], {
				name: 'xterm-256color'
				cols: 80
				rows: 24
				cwd: proj.dir
				env: process.env
			})
			#terminals[id] = { pty: term, ws }
			term.onData do(data)
				try ws.send(data)
			term.onExit do
				try ws.close!
				delete #terminals[id]
				log "terminal closed: {id}"
		else
			# Fallback: pipe-based terminal (no job control)
			const proc = Bun.spawn(["bash", "-i"], {
				cwd: proj.dir
				stdin: "pipe"
				stdout: "pipe"
				stderr: "pipe"
			})
			#terminals[id] = { proc, ws }
			const pumpStream = do(stream)
				try
					const reader = stream.getReader!
					while yes
						const {done, value} = await reader.read!
						break if done
						try ws.send(value)
				catch e
					return
			pumpStream(proc.stdout)
			pumpStream(proc.stderr)
			const terms = #terminals
			proc.exited.then do
				try ws.close!
				delete terms[id]
				log "terminal closed: {id}"

	def wsMessage ws, msg
		const t = #terminals[ws.data..termId]
		return unless t
		if t.pty
			const data = typeof msg == 'string' ? msg : new TextDecoder!.decode(msg)
			# Handle resize messages (JSON: {type:'resize', cols, rows})
			if data[0] == '{'
				try
					const r = JSON.parse(data)
					if r.type == 'resize' and r.cols and r.rows
						t.pty.resize(r.cols, r.rows)
						return
			t.pty.write(data)
		elif t.proc and t.proc.stdin
			try t.proc.stdin.write(msg)

	def wsClose ws
		const id = ws.data..termId
		const t = #terminals[id]
		if t
			if t.pty
				try t.pty.kill!
			elif t.proc
				try t.proc.kill!
			delete #terminals[id]
			log "terminal disconnected: {id}"

	# --- HTTP-based terminal sessions ---

	def termSpawn pid
		const proj = #connector.project(pid)
		unless proj
			return { error: "no project" }
		const id = Math.random!.toString(36).slice(2) + Math.random!.toString(36).slice(2)
		const proc = Bun.spawn(["bash", "-i"], {
			cwd: proj.dir
			stdin: "pipe"
			stdout: "pipe"
			stderr: "pipe"
		})
		const session = { proc, buffer: [], alive: yes }
		#httpTerminals[id] = session
		log "terminal.spawn: {id} (project {pid})"

		# Pipe stdout → buffer
		const pumpStream = do(stream)
			try
				const reader = stream.getReader!
				while yes
					const {done, value} = await reader.read!
					break if done
					if session.alive
						# Convert Uint8Array to string for JSON transport
						const text = new TextDecoder!.decode(value)
						session.buffer.push(text)
			catch e
				return

		pumpStream(proc.stdout)
		pumpStream(proc.stderr)

		# Handle process exit
		const terms = #httpTerminals
		proc.exited.then do
			session.alive = no
			session.buffer.push("\r\n[process exited]")
			log "terminal.exited: {id}"
			# Auto-cleanup after 30s
			setTimeout(&, 30000) do
				delete terms[id]

		{ ok: yes, sessionId: id }

	def termInput sessionId, data
		const s = #httpTerminals[sessionId]
		unless s and s.alive
			return { error: "no session" }
		try
			s.proc.stdin.write(data)
			return { ok: yes }
		catch e
			return { error: "write failed" }

	def termOutput sessionId
		const s = #httpTerminals[sessionId]
		unless s
			return { error: "no session" }
		const out = s.buffer.splice(0)
		{ ok: yes, data: out.join(""), alive: s.alive }

	def termResize sessionId, cols, rows
		# Bun.spawn doesn't support resize without node-pty
		{ ok: yes }

	def termClose sessionId
		const s = #httpTerminals[sessionId]
		if s
			s.alive = no
			try s.proc.kill!
			delete #httpTerminals[sessionId]
			log "terminal.close: {sessionId}"
		{ ok: yes }

	def respond data, code = 200
		Response.json(data, status: code)
