# Route handlers mounted on the HTTPS server. Filled in Wave 6.
export def registerRoutes server, connector
	server.route('POST', '/invoke', do
		{ status: 501, body: { error: 'invoke not implemented in Phase 1' } })
