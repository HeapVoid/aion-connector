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

	server.route 'POST', '/coordinator/sync/persona', do(params, body)
		unless body and body.content !== undefined
			return { status: 400, body: { error: 'content required' } }
		try
			const curr = await connector.adapter.readSkills!
			const skillsPayload = curr.skills.map do(s) { name: s.name, content: s.content }
			const out = await connector.adapter.writeSkills({ persona: body.content, expected_persona_hash: body.expected_prev_hash, skills: skillsPayload })
			{ status: 200, body: { persona: out.persona } }
		catch e
			if e.constructor and e.constructor.name == 'ConflictError'
				return { status: 409, body: { error: 'conflict', actualHash: e.actualHash } }
			{ status: 500, body: { error: e.message } }

	server.route 'POST', '/coordinator/sync/read', do
		const r = await connector.adapter.readSkills!
		{ status: 200, body: r }

	server.route 'POST', '/coordinator/sync/skills', do(params, body)
		unless body and Array.isArray(body.skills)
			return { status: 400, body: { error: 'skills array required' } }
		try
			const curr = await connector.adapter.readSkills!
			const personaContent = (curr.persona and curr.persona.content) or ''
			const out = await connector.adapter.writeSkills({ persona: personaContent, skills: body.skills })
			{ status: 200, body: { skills: out.skills } }
		catch e
			if e.constructor and e.constructor.name == 'ConflictError'
				return { status: 409, body: { error: 'conflict', actualHash: e.actualHash } }
			{ status: 500, body: { error: e.message } }

	server.route 'POST', '/coordinator/update', do(params, body)
		body = body or {}
		try
			if body.model !== undefined or body.persona !== undefined or body.skills !== undefined or body.credentials !== undefined
				const curr = await connector.adapter.readSkills!
				const personaContent = body.persona !== undefined ? body.persona : ((curr.persona and curr.persona.content) or '')
				const skillsContent = body.skills !== undefined ? body.skills : curr.skills.map(do(s) { name: s.name, content: s.content })
				await connector.adapter.configure({
					model: body.model
					persona: personaContent
					skills: skillsContent
					credentials: body.credentials
				})
				await connector.adapter.restart!
			{ status: 200, body: { status: 'updated' } }
		catch e
			{ status: 500, body: { status: 'error', error: e.message } }
