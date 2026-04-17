import {test, expect, beforeEach, afterEach} from "bun:test"
import {mkdtempSync} from 'fs'
import {tmpdir} from 'os'
import {join} from 'path'
import {MockAion} from "../dev/mock-aion.imba"
import {AionClient} from "../src/aion-client.imba"
import {generateSelfSigned} from "../src/tls.imba"
import {writeState, readState, certPath, keyPath, ensureDirs} from "../src/state.imba"
import {Connector} from "../src/connector.imba"
import {pickFreePort} from "../src/port.imba"

let aion = null
let sandbox = null
let oldHome = null

beforeEach do
	aion = new MockAion!
	await aion.start!
	sandbox = mkdtempSync(join(tmpdir!, 'aion-run-'))
	oldHome = process.env.HOME
	process.env.HOME = sandbox
	process.env.AION_EXTERNAL_IP = '1.2.3.4'

afterEach do
	process.env.HOME = oldHome
	delete process.env.AION_EXTERNAL_IP
	await aion.stop!

test "Connector.start sends a heartbeat within 2s", do
	const { workspace_id, enrollment_token } = aion.createWorkspace!
	ensureDirs!
	const fp = await generateSelfSigned(certPath!, keyPath!)
	const port = await pickFreePort(18200, 18299)
	const cli = new AionClient(aion.baseUrl)
	const reg = await cli.register({
		enrollment_token, external_ip: '1.2.3.4', port
		cert_fingerprint: fp, coordinator_status: { state: 'ready', program: 'stub' }
		connector_version: '0.4.0'
	})
	writeState({
		workspace_id: reg.workspace_id, workspace_token: reg.workspace_token
		aion_url: aion.baseUrl, port, cert_fingerprint: fp
		coordinator: { program: 'stub', model: 'm', auth_mode: 'api_key' }
	})
	const state = readState!
	const c = new Connector(state)
	await c.start!
	await new Promise do(ok) setTimeout(ok, 100)
	expect(aion.heartbeats.length).toBeGreaterThanOrEqual(1)
	await c.stop!
