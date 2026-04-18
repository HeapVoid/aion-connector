import {test, expect, beforeEach, afterEach} from "bun:test"
import {mkdtempSync} from 'fs'
import {tmpdir} from 'os'
import {join} from 'path'
import {generateSelfSigned, loadCertKey} from "../src/tls.imba"
import {Server} from "../src/server.imba"
import {registerRoutes} from "../src/routes.imba"
import {StubAdapter} from "../src/adapter.imba"

let server = null
let port = 0
const token = 'tok'

const _fetch = globalThis.fetch.bind(globalThis)

beforeEach do
	const dir = mkdtempSync(join(tmpdir!, 'aion-routes-'))
	const certP = join(dir, 'cert.pem')
	const keyP = join(dir, 'key.pem')
	await generateSelfSigned(certP, keyP)
	const { cert, key } = loadCertKey(certP, keyP)
	port = 19400 + Math.floor(Math.random! * 200)
	server = new Server({ port, cert, key, aionToken: token })
	const adapter = new StubAdapter(dir)
	adapter.startAuth = do
		return { url: 'https://provider.example/oauth?session=abc' }
	adapter.submitAuthCode = do(o)
		if o.code === 'good'
			return { status: 'authorized' }
		return { status: 'error', error: 'bad code' }
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

test "/coordinator/oauth/start returns url", do
	const res = await post('/coordinator/oauth/start', {})
	expect(res.status).toBe(200)
	const b = await res.json!
	expect(b.url).toBe('https://provider.example/oauth?session=abc')

test "/coordinator/oauth/complete with good code", do
	const res = await post('/coordinator/oauth/complete', { code: 'good' })
	expect(res.status).toBe(200)
	const b = await res.json!
	expect(b.status).toBe('authorized')

test "/coordinator/oauth/complete with bad code returns 400", do
	const res = await post('/coordinator/oauth/complete', { code: 'bad' })
	expect(res.status).toBe(400)
