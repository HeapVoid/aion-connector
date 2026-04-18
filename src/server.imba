# Minimal HTTPS server with bearer-token auth.
# Route handlers are plugged in by Connector via route(method, path, handler).
# Server itself only owns: TLS boot, body parse, auth, error shape, logging.
import * as https from 'https'
import {VERSION} from './protocol.imba'
import {log, error} from './utils.imba'

export class Server
	host = '0.0.0.0'
	port = 0
	cert = null
	key = null
	aionToken = null
	routes = []
	srv = null

	def constructor opts
		self.port = opts.port
		self.cert = opts.cert
		self.key = opts.key
		self.aionToken = opts.aionToken
		self.host = opts.host or '0.0.0.0'

	def route method, path, handler
		const parts = path.split('/').filter(do(s) s.length > 0)
		const matcher = do(url)
			const u = url.split('?')[0].split('/').filter(do(s) s.length > 0)
			return null if u.length !== parts.length
			const params = {}
			let i = 0
			while i < parts.length
				const seg = parts[i]
				if seg[0] === ':'
					params[seg.slice(1)] = u[i]
				elif seg !== u[i]
					return null
				i = i + 1
			params
		routes.push({ method: method, matcher: matcher, handler: handler, path: path })

	def start
		const self2 = self
		srv = https.createServer({ cert: cert, key: key }, do(req, res) self2.handle(req, res))
		await new Promise do(ok) srv.listen(port, host, do ok())
		log("https listening on {host}:{port}")

	def stop
		return unless srv
		await new Promise do(ok) srv.close(do ok())

	def handle req, res
		try
			const auth = req.headers['authorization'] or ''
			const tok = auth.replace(/^Bearer /, '')
			unless tok and tok === aionToken
				return self.reply(res, 403, { error: 'unauthorized' })

			let body = null
			if req.method === 'POST'
				let raw = ''
				await new Promise do(ok)
					req.on('data', do(c) raw = raw + c.toString())
					req.on('end', do ok())
				if raw.length > 0
					try
						body = JSON.parse(raw)
					catch e
						return self.reply(res, 400, { error: 'invalid json' })
				if body and body.v and body.v > VERSION
					return self.reply(res, 400, { error: 'version', min: body.v })

			if req.method === 'POST' and (req.url === '/ping' or req.url === '/')
				return self.reply(res, 200, { ok: yes, v: VERSION })

			let i = 0
			while i < routes.length
				const r = routes[i]
				if r.method === req.method
					const params = r.matcher(req.url)
					if params
						const out = await r.handler(params, body, req)
						return self.reply(res, out.status or 200, out.body or { ok: yes })
				i = i + 1
			self.reply(res, 404, { error: 'not found' })
		catch e
			error("route error: {e.message}")
			self.reply(res, 500, { error: 'internal' })

	def reply res, code, data
		res.writeHead(code, { 'content-type': 'application/json' })
		res.end(JSON.stringify(data))
