import {test, expect, beforeEach, afterEach} from "bun:test"
import {mkdtempSync} from 'fs'
import {tmpdir} from 'os'
import {join} from 'path'
import {generateSelfSigned, loadCertKey} from "../src/tls.imba"
import {Server} from "../src/server.imba"
import {registerRoutes} from "../src/routes.imba"
import {StubAdapter} from "../src/adapter.imba"

const _fetch = globalThis.fetch.bind(globalThis)

let server = null
let port = 0
let home = null
const token = 'tok'

beforeEach do
	home = mkdtempSync(join(tmpdir!, 'aion-sync-home-'))
	const certP = join(home, 'cert.pem')
	const keyP = join(home, 'key.pem')
	await generateSelfSigned(certP, keyP)
	const { cert, key } = loadCertKey(certP, keyP)
	port = 19600 + Math.floor(Math.random! * 200)
	server = new Server({ port, cert, key, workspaceToken: token })
	const adapter = new StubAdapter(home)
	await adapter.configure({ persona: 'v1', skills: [{ name: 'a', content: 'x' }], model: 'm', credentials: null })
	registerRoutes(server, { adapter })
	await server.start!

afterEach do
	await server.stop!

def post path, body
	_fetch("https://127.0.0.1:{port}{path}", {
		method: 'POST'
		headers: { 'content-type': 'application/json', 'authorization': "Bearer {token}" }
		body: JSON.stringify(body or {})
		tls: { rejectUnauthorized: false }
	})

test "sync/read returns persona + skills", do
	const res = await post('/coordinator/sync/read', {})
	expect(res.status).toBe(200)
	const b = await res.json!
	expect(b.persona.content).toBe('v1')
	expect(b.skills.length).toBe(1)
	expect(b.skills[0].name).toBe('a')

test "sync/persona overwrites persona", do
	const res = await post('/coordinator/sync/persona', { content: 'v2' })
	expect(res.status).toBe(200)
	const read = await (await post('/coordinator/sync/read', {})).json!
	expect(read.persona.content).toBe('v2')

test "sync/skills replaces skills", do
	const res = await post('/coordinator/sync/skills', { skills: [{ name: 'b', content: 'y' }] })
	expect(res.status).toBe(200)
	const read = await (await post('/coordinator/sync/read', {})).json!
	expect(read.skills.length).toBe(1)
	expect(read.skills[0].name).toBe('b')
