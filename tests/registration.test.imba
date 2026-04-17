import {test, expect, beforeEach, afterEach} from "bun:test"
import {mkdtempSync} from 'fs'
import {tmpdir} from 'os'
import {join} from 'path'
import {MockAion} from "../dev/mock-aion.imba"
import {AionClient} from "../src/aion-client.imba"
import {generateSelfSigned} from "../src/tls.imba"
import {writeState, readState, certPath, keyPath, ensureDirs} from "../src/state.imba"
import {makeAdapter} from "../src/adapter.imba"
import {pickFreePort} from "../src/port.imba"

let aion = null
let sandbox = null
let oldHome = null

beforeEach do
	aion = new MockAion!
	await aion.start!
	sandbox = mkdtempSync(join(tmpdir!, 'aion-home-'))
	oldHome = process.env.HOME
	process.env.HOME = sandbox

afterEach do
	process.env.HOME = oldHome
	await aion.stop!

test "end-to-end registration with stub adapter", do
	const ws = aion.createWorkspace({ program: 'stub' })
	ensureDirs()
	const fp = await generateSelfSigned(certPath(), keyPath())
	const port = await pickFreePort(18100, 18199)
	const adapter = makeAdapter('stub', sandbox)
	await adapter.installCoordinator({ program: 'stub' })
	await adapter.configure({ persona: 'p', skills: [], model: 'm', credentials: null })
	await adapter.start()
	const cli = new AionClient(aion.baseUrl)
	const reg = await cli.register({
		enrollment_token: ws.enrollment_token
		external_ip: '1.2.3.4'
		port: port
		cert_fingerprint: fp
		coordinator_status: { state: 'ready', program: 'stub', version: '1' }
		connector_version: '0.4.0'
	})
	expect(reg.workspace_id).toBe(ws.workspace_id)
	writeState({
		workspace_id: reg.workspace_id
		workspace_token: reg.workspace_token
		aion_url: aion.baseUrl
		port: port
		cert_fingerprint: fp
		coordinator: { program: 'stub', model: 'm', auth_mode: 'api_key' }
	})
	const st = readState()
	expect(st.workspace_id).toBe(ws.workspace_id)
	const wsRec = aion.workspaces.get(ws.workspace_id)
	expect(wsRec.state).toBe('online')
	expect(wsRec.port).toBe(port)
	expect(wsRec.fingerprint).toBe(fp)
