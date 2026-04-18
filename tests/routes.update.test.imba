import {test, expect, beforeEach, afterEach} from "bun:test"
import {mkdtempSync, readFileSync} from 'fs'
import {tmpdir} from 'os'
import {join} from 'path'
import {generateSelfSigned, loadCertKey} from "../src/tls.imba"
import {Server} from "../src/server.imba"
import {registerRoutes} from "../src/routes.imba"
import {StubAdapter} from "../src/adapter.imba"
import {personaPath} from "../src/sync.imba"

const _fetch = globalThis.fetch.bind(globalThis)

let server = null
let port = 0
let home = null
const token = 'tok'

beforeEach do
	home = mkdtempSync(join(tmpdir!, 'aion-up-'))
	const certP = join(home, 'cert.pem')
	const keyP = join(home, 'key.pem')
	await generateSelfSigned(certP, keyP)
	const { cert, key } = loadCertKey(certP, keyP)
	port = 19900 + Math.floor(Math.random! * 100)
	server = new Server({ port, cert, key, aionToken: token })
	const adapter = new StubAdapter(home)
	await adapter.configure({ persona: 'v1', skills: [], model: 'm1', credentials: null })
	registerRoutes(server, { adapter })
	await server.start!

afterEach do
	await server.stop!

test "update applies new persona via configure", do
	const res = await _fetch "https://127.0.0.1:{port}/coordinator/update",
		method: 'POST'
		headers: { 'content-type': 'application/json', 'authorization': "Bearer {token}" }
		body: JSON.stringify({ persona: 'v2' })
		tls: { rejectUnauthorized: false }
	expect(res.status).toBe(200)
	expect(readFileSync(personaPath(home), 'utf8')).toBe('v2')
