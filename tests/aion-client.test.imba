import {test, expect, beforeEach, afterEach} from "bun:test"
import {MockAion} from "../dev/mock-aion.imba"
import {AionClient} from "../src/aion-client.imba"

let aion = null
beforeEach do
	aion = new MockAion!
	await aion.start!
afterEach do
	await aion.stop!

test "register returns workspace_id + workspace_token", do
	const ws = aion.createWorkspace!
	const cli = new AionClient(aion.baseUrl)
	const r = await cli.register({
		enrollment_token: ws.enrollment_token
		external_ip: '1.2.3.4'
		port: 7700
		cert_fingerprint: '0'.repeat(64)
		coordinator_status: { state: 'ready', program: 'stub', version: '1' }
		connector_version: '0.4.0'
	})
	expect(r.workspace_id).toBe(ws.workspace_id)
	expect(typeof r.workspace_token).toBe('string')

test "register with bad enrollment token throws", do
	const cli = new AionClient(aion.baseUrl)
	let threw = no
	try
		await cli.register({
			enrollment_token: 'bogus'
			external_ip: '1.2.3.4'
			port: 7700
			cert_fingerprint: '0'.repeat(64)
			coordinator_status: { state: 'ready' }
			connector_version: '0.4.0'
		})
	catch e
		threw = yes
	expect(threw).toBe(true)

test "heartbeat requires workspace_token", do
	const ws = aion.createWorkspace!
	const cli = new AionClient(aion.baseUrl)
	const reg = await cli.register({
		enrollment_token: ws.enrollment_token
		external_ip: '1.2.3.4'
		port: 7700
		cert_fingerprint: '0'.repeat(64)
		coordinator_status: { state: 'ready' }
		connector_version: '0.4.0'
	})
	cli.setWorkspaceToken(reg.workspace_token)
	await cli.heartbeat(ws.workspace_id, {
		external_ip: '1.2.3.4'
		coordinator_status: { state: 'ready' }
		connector_version: '0.4.0'
	})
	expect(aion.heartbeats.length).toBe(1)
