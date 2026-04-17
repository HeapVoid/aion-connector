import {test, expect, beforeEach, afterEach} from "bun:test"
import {MockAion} from "../dev/mock-aion.imba"

let aion = null

beforeEach do
	aion = new MockAion!
	await aion.start!

afterEach do
	await aion.stop!

test "register with valid enrollment_token returns workspace_token", do
	const { workspace_id, enrollment_token } = aion.createWorkspace({ program: "claude-code" })
	const res = await fetch "{aion.baseUrl}/api/workspaces/register",
		method: 'POST'
		headers: { 'content-type': 'application/json' }
		body: JSON.stringify({
			enrollment_token
			external_ip: '203.0.113.42'
			port: 7700
			cert_fingerprint: '00'.repeat(32)
			coordinator_status: { state: 'ready', program: 'claude-code', version: '1.0' }
			connector_version: '0.4.0'
		})
	expect(res.status).toBe(200)
	const body = await res.json!
	expect(body.workspace_id).toBe(workspace_id)
	expect(typeof body.workspace_token).toBe('string')
	expect(body.workspace_token.length).toBeGreaterThan(32)

test "register with unknown enrollment_token returns 401", do
	const res = await fetch "{aion.baseUrl}/api/workspaces/register",
		method: 'POST'
		headers: { 'content-type': 'application/json' }
		body: JSON.stringify({ enrollment_token: 'bogus' })
	expect(res.status).toBe(401)

test "heartbeat with bearer token updates state", do
	const { workspace_id, enrollment_token } = aion.createWorkspace!
	const reg = await fetch "{aion.baseUrl}/api/workspaces/register",
		method: 'POST'
		headers: { 'content-type': 'application/json' }
		body: JSON.stringify({ enrollment_token, external_ip: '1.2.3.4', port: 7700, cert_fingerprint: '0'.repeat(64), coordinator_status: { state: 'ready' }, connector_version: '0.4.0' })
	const { workspace_token } = await reg.json!
	const hb = await fetch "{aion.baseUrl}/api/workspaces/{workspace_id}/heartbeat",
		method: 'POST'
		headers: { 'content-type': 'application/json', 'authorization': "Bearer {workspace_token}" }
		body: JSON.stringify({ external_ip: '1.2.3.4', coordinator_status: { state: 'ready' }, connector_version: '0.4.0', timestamp: Date.now! })
	expect(hb.status).toBe(200)
	expect(aion.heartbeats.length).toBe(1)
