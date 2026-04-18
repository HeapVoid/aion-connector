# In-memory mock AION server for integration tests.
# Implements the five endpoints: create, register, heartbeat, re-enroll, delete.
import {createServer} from 'http'
import {randomUUID, randomBytes} from 'crypto'

export class MockAion
	port = 0
	workspaces = new Map!        # workspace_id → record
	enrollments = new Map!       # enrollment_token → workspace_id
	workspaceTokens = new Map!   # workspace_token → workspace_id
	heartbeats = []              # recent heartbeats for assertions
	server = null

	def createWorkspace coordinatorConfig = {}
		const id = randomUUID!
		const enrollment = randomBytes(16).toString('hex')
		const now = Date.now!
		workspaces.set(id, {
			id
			state: 'provisioning'
			coordinator: coordinatorConfig
			ip: null
			port: null
			fingerprint: null
			createdAt: now
			updatedAt: now
		})
		enrollments.set(enrollment, id)
		return { workspace_id: id, enrollment_token: enrollment }

	def start
		server = createServer do(req, res) handle(req, res)
		return new Promise do(ok)
			server.listen 0, '127.0.0.1', do
				port = server.address!.port
				ok(port)

	def stop
		return unless server
		return new Promise do(ok) server.close do ok!

	get baseUrl
		"http://127.0.0.1:{port}"

	def handle req, res
		let body = ''
		req.on('data', do(c) body += c)
		req.on('end', do
			let payload = {}
			if body
				try payload = JSON.parse(body)
				catch
					return json(res, 400, { error: "invalid json" })
			try
				await route(req.method, req.url, payload, req.headers, res)
			catch e
				json(res, 500, { error: e.message })
		)

	def route method, url, payload, headers, res
		if method == 'POST' and url == '/api/workspaces/register'
			return handleRegister(payload, res)
		if method == 'POST' and url.match(/^\/api\/workspaces\/[^\/]+\/heartbeat$/)
			const id = url.split('/')[3]
			return handleHeartbeat(id, payload, headers, res)
		json(res, 404, { error: "not found" })

	def handleRegister payload, res
		const { enrollment_token, external_ip, port: connPort, cert_fingerprint, coordinator_status, connector_version } = payload
		const id = enrollments.get(enrollment_token)
		unless id
			return json(res, 401, { error: "invalid enrollment_token" })
		enrollments.delete(enrollment_token)
		const token = randomBytes(32).toString('hex')
		const ws = workspaces.get(id)
		ws.ip = external_ip
		ws.port = connPort
		ws.fingerprint = cert_fingerprint
		ws.connector_version = connector_version
		ws.coordinator_status = coordinator_status
		ws.workspace_token = token
		const aionToken = randomBytes(32).toString('hex')
		ws.aion_token = aionToken
		ws.state = coordinator_status..state == 'ready' ? 'online' : 'provisioning'
		ws.updatedAt = Date.now!
		workspaceTokens.set(token, id)
		json(res, 200, { workspace_id: id, workspace_token: token, aion_token: aionToken })

	def handleHeartbeat id, payload, headers, res
		const auth = headers['authorization'] or ''
		const token = auth.replace(/^Bearer /, '')
		const expected = workspaces.get(id)..workspace_token
		unless token and token == expected
			return json(res, 401, { error: "unauthorized" })
		const ws = workspaces.get(id)
		ws.ip = payload.external_ip or ws.ip
		ws.coordinator_status = payload.coordinator_status
		ws.lastHeartbeat = Date.now!
		ws.state = payload.coordinator_status..state == 'ready' ? 'online' : 'degraded'
		heartbeats.push({ id, at: ws.lastHeartbeat, payload })
		json(res, 200, { ok: true })

	def json res, code, data
		res.writeHead(code, { 'content-type': 'application/json' })
		res.end(JSON.stringify(data))
