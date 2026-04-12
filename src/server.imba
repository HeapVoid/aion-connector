import {VERSION} from './protocol.imba'
import {log} from './utils.imba'
import {createServer} from 'http'
import {WebSocketServer} from 'ws'
import {spawn} from 'child_process'

# Try to load node-pty for proper PTY terminal (colors, job control, readline)
let pty = null
try
	pty = require('node-pty')
	log "node-pty loaded — full PTY terminal available"
catch
	log "node-pty not available — using pipe-based terminal (no job control)"

export class Server
	#connector
	#http = null
	#wss = null
	#terminals = {}
	#httpTerminals = {}
	#meta = new WeakMap!

	def constructor connector
		#connector = connector

	def start
		const srv = this
		#http = createServer(do(req, res) srv.handleHttp(req, res))
		#wss = new WebSocketServer({ noServer: yes })
		#http.on('upgrade', do(req, socket, head) srv.handleUpgrade(req, socket, head))
		#http.listen #connector.port, #connector.host, do
			log "listening on {#connector.host}:{#connector.port}"

	def stop
		for own id, t of #terminals
			if t.pty
				try t.pty.kill!
			elif t.proc
				try t.proc.kill!
		#terminals = {}
		for own id, s of #httpTerminals
			try s.proc.kill!
		#httpTerminals = {}
		#http..close!

	# --- HTTP ---

	def handleHttp req, res
		unless req.method == "POST"
			return respond(res, { error: "POST only" }, 405)
		let body = ''
		req.on('data', do(chunk) body += chunk)
		req.on('end', do
			let msg
			try
				msg = JSON.parse(body)
			catch
				return respond(res, { error: "invalid json" }, 400)
			self.route(msg, res)
		)

	def route msg, res
		if msg.v and msg.v > VERSION
			return respond(res, { error: "version", min: msg.v }, 400)

		const pid = #connector.auth(msg.token)
		unless pid
			return respond(res, { error: "unauthorized" }, 403)

		const p = msg.payload or {}
		if p.project and p.project != pid
			return respond(res, { error: "token/project mismatch" }, 403)

		p.project = pid

		switch msg.action
			when "invoke"
				#connector.invoke(p)
				respond(res, { ok: yes })
			when "agents"
				respond(res, { agents: #connector.agents(pid) })
			when "repos.sync"
				const ws = #connector.workspace(pid)
				if ws
					await ws.repos.sync(p.repos or [])
				respond(res, { ok: yes })
			when "files.tree"
				const files = #connector.filesFor(pid)
				respond(res, files ? await files.tree(p) : { error: "no workspace" })
			when "files.read"
				const files = #connector.filesFor(pid)
				respond(res, files ? await files.read(p) : { error: "no workspace" })
			when "git.status"
				const files = #connector.filesFor(pid)
				respond(res, files ? await files.status(p) : { error: "no workspace" })
			when "git.diff"
				const files = #connector.filesFor(pid)
				respond(res, files ? await files.diff(p) : { error: "no workspace" })
			when "workspaces"
				const ws = #connector.workspace(pid)
				respond(res, { list: ws ? ws.repos.list! : [] })
			when "terminal.spawn"
				respond(res, termSpawn(pid))
			when "terminal.input"
				respond(res, termInput(p.sessionId, p.data))
			when "terminal.output"
				respond(res, termOutput(p.sessionId))
			when "terminal.resize"
				respond(res, termResize(p.sessionId, p.cols, p.rows))
			when "terminal.close"
				respond(res, termClose(p.sessionId))
			when "ping"
				respond(res, { ok: yes, v: VERSION })
			else
				respond(res, { error: "unknown action" }, 400)

	# --- WebSocket terminal ---

	def handleUpgrade req, socket, head
		const url = new URL(req.url, "http://localhost")
		const token = url.searchParams.get("token")
		const pid = #connector.auth(token)
		unless pid
			socket.write("HTTP/1.1 403 Forbidden\r\n\r\n")
			socket.destroy!
			return
		const srv = self
		#wss.handleUpgrade(req, socket, head, do(ws)
			#meta.set(ws, { pid })
			srv.wsOpen(ws)
			ws.on('message', do(msg) srv.wsMessage(ws, msg))
			ws.on('close', do srv.wsClose(ws))
		)

	def wsOpen ws
		const info = #meta.get(ws)
		const proj = #connector.project(info.pid)
		unless proj
			ws.close!
			return
		const id = Math.random!.toString(36).slice(2)
		info.termId = id
		log "terminal opened: {id} (project {info.pid})"

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
			const proc = spawn('bash', ['-i'], {
				cwd: proj.dir
				stdio: ['pipe', 'pipe', 'pipe']
			})
			#terminals[id] = { proc, ws }
			proc.stdout.on('data', do(chunk) try ws.send(chunk))
			proc.stderr.on('data', do(chunk) try ws.send(chunk))
			proc.on('close', do
				try ws.close!
				delete #terminals[id]
				log "terminal closed: {id}"
			)

	def wsMessage ws, msg
		const info = #meta.get(ws)
		return unless info
		const t = #terminals[info.termId]
		return unless t
		if t.pty
			const data = typeof msg == 'string' ? msg : msg.toString!
			# Handle resize messages (JSON: {type:'resize', cols, rows})
			if data[0] == '{'
				try
					const r = JSON.parse(data)
					if r.type == 'resize' and r.cols and r.rows
						t.pty.resize(r.cols, r.rows)
						return
			t.pty.write(data)
		elif t.proc and t.proc.stdin
			t.proc.stdin.write(msg)

	def wsClose ws
		const info = #meta.get(ws)
		return unless info
		const id = info.termId
		const t = #terminals[id]
		if t
			if t.pty
				try t.pty.kill!
			elif t.proc
				try t.proc.kill!
			delete #terminals[id]
			log "terminal disconnected: {id}"
		#meta.delete(ws)

	# --- HTTP-based terminal sessions ---

	def termSpawn pid
		const proj = #connector.project(pid)
		unless proj
			return { error: "no project" }
		const id = Math.random!.toString(36).slice(2) + Math.random!.toString(36).slice(2)
		const proc = spawn('bash', ['-i'], {
			cwd: proj.dir
			stdio: ['pipe', 'pipe', 'pipe']
		})
		const session = { proc, buffer: [], alive: yes }
		#httpTerminals[id] = session
		log "terminal.spawn: {id} (project {pid})"

		proc.stdout.on('data', do(chunk)
			if session.alive
				session.buffer.push(chunk.toString!)
		)
		proc.stderr.on('data', do(chunk)
			if session.alive
				session.buffer.push(chunk.toString!)
		)

		const terms = #httpTerminals
		proc.on('close', do
			session.alive = no
			session.buffer.push("\r\n[process exited]")
			log "terminal.exited: {id}"
			setTimeout(&, 30000) do
				delete terms[id]
		)

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
		{ ok: yes }

	def termClose sessionId
		const s = #httpTerminals[sessionId]
		if s
			s.alive = no
			try s.proc.kill!
			delete #httpTerminals[sessionId]
			log "terminal.close: {sessionId}"
		{ ok: yes }

	def respond res, data, code = 200
		res.writeHead(code, { 'Content-Type': 'application/json' })
		res.end(JSON.stringify(data))
