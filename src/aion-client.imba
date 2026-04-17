import {VERSION} from './protocol.imba'

const _fetch = globalThis.fetch.bind(globalThis)

# HTTPS client for AION control-plane API. One instance per connector process.
# Methods throw on HTTP errors; caller decides retry policy.
export class AionClient
	baseUrl = null
	workspaceToken = null

	def constructor url, token = null
		self.baseUrl = url.replace(/\/$/, '')
		self.workspaceToken = token

	def setWorkspaceToken t
		self.workspaceToken = t

	def register payload
		const res = await _fetch "{baseUrl}/api/workspaces/register",
			method: 'POST'
			headers: { 'content-type': 'application/json' }
			body: JSON.stringify(Object.assign({}, payload, { v: VERSION }))
		let body = null
		try
			body = await res.json!
		catch e
			body = {}
		unless res.ok
			throw new Error("register failed: {res.status} {body.error or ''}")
		body

	def heartbeat workspaceId, payload
		const res = await _fetch "{baseUrl}/api/workspaces/{workspaceId}/heartbeat",
			method: 'POST'
			headers: { 'content-type': 'application/json', 'authorization': "Bearer {workspaceToken}" }
			body: JSON.stringify(Object.assign({}, payload, { timestamp: Date.now!, v: VERSION }))
		let body = null
		try
			body = await res.json!
		catch e
			body = {}
		unless res.ok
			throw new Error("heartbeat failed: {res.status} {body.error or ''}")
		body

	def certRotated workspaceId, newFingerprint
		const res = await _fetch "{baseUrl}/api/workspaces/{workspaceId}/cert-rotated",
			method: 'POST'
			headers: { 'content-type': 'application/json', 'authorization': "Bearer {workspaceToken}" }
			body: JSON.stringify({ cert_fingerprint: newFingerprint, v: VERSION })
		res.ok
