import {test, expect, beforeEach, afterEach} from "bun:test"
import {MockAion} from "../dev/mock-aion.imba"
import {AionClient} from "../src/aion-client.imba"
import {Heartbeat} from "../src/heartbeat.imba"

let aion = null
beforeEach do
	aion = new MockAion!
	await aion.start!
afterEach do
	await aion.stop!

def registerWorkspace
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
	{ cli: cli, workspace_id: ws.workspace_id }

const _setTimeout = globalThis.setTimeout.bind(globalThis)

test "heartbeat fires immediately and then on interval", do
	const reg = await registerWorkspace()
	let calls = 0
	const hb = new Heartbeat({
		aionClient: reg.cli
		workspaceId: reg.workspace_id
		intervalMs: 50
		collect: do
			calls = calls + 1
			{ external_ip: '1.2.3.4', coordinator_status: { state: 'ready' }, connector_version: '0.4.0' }
	})
	hb.start!
	await new Promise do(ok) _setTimeout(ok, 200)
	hb.stop!
	expect(calls).toBeGreaterThanOrEqual(3)
	expect(aion.heartbeats.length).toBe(calls)

test "heartbeat swallows network errors", do
	await aion.stop!
	const cli = new AionClient("http://127.0.0.1:1")
	cli.setWorkspaceToken('x')
	const hb = new Heartbeat({
		aionClient: cli
		workspaceId: 'x'
		intervalMs: 50
		collect: do { external_ip: '1.2.3.4', coordinator_status: { state: 'ready' }, connector_version: '0.4.0' }
	})
	hb.start!
	await new Promise do(ok) _setTimeout(ok, 120)
	hb.stop!
	aion = new MockAion!
	await aion.start!
