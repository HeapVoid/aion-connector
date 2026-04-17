# Route handlers mounted on the HTTPS server. Filled in Wave 6.
export def registerRoutes server, connector
	server.route 'POST', '/invoke', do
		{ status: 501, body: { error: 'invoke not implemented in Phase 1' } }

	server.route 'POST', '/coordinator/oauth/start', do
		try
			const r = await connector.adapter.startAuth!
			if r == null
				return { status: 400, body: { error: 'adapter is api-key only' } }
			{ status: 200, body: { url: r.url } }
		catch e
			{ status: 500, body: { error: e.message } }

	server.route 'POST', '/coordinator/oauth/complete', do(params, body)
		unless body and body.code
			return { status: 400, body: { error: 'code required' } }
		const r = await connector.adapter.submitAuthCode({ code: body.code })
		{ status: r.status == 'authorized' ? 200 : 400, body: r }
