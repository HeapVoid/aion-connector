#!/usr/bin/env node

// AION MCP Server — tools for agents running in the AION platform
// Spawned by connector as stdio MCP server per agent session.
// Env: AION_CALLBACK, AION_TOKEN, AION_SESSION_ID

const CALLBACK = process.env.AION_CALLBACK || ''
const TOKEN = process.env.AION_TOKEN || ''
const SESSION_ID = process.env.AION_SESSION_ID || ''

const TOOLS = [
	{
		name: 'display_set',
		description: 'Show a URL in the team display panel. The display panel is an iframe visible to all team members in the server UI. Use it to share live previews, dashboards, documentation, or any web content. The URL must be accessible from team members\' browsers (not localhost on the server).',
		inputSchema: {
			type: 'object',
			properties: {
				url: { type: 'string', description: 'The URL to display' }
			},
			required: ['url']
		}
	},
	{
		name: 'display_clear',
		description: 'Clear the team display panel, removing the currently shown content.',
		inputSchema: { type: 'object', properties: {} }
	}
]

// --- MCP protocol (Content-Length framing) ---

function send(msg) {
	const json = JSON.stringify(msg)
	const len = Buffer.byteLength(json)
	process.stdout.write(`Content-Length: ${len}\r\n\r\n${json}`)
}

let buffer = ''
process.stdin.setEncoding('utf8')
process.stdin.on('data', chunk => {
	buffer += chunk
	processBuffer()
})

let processing = false
async function processBuffer() {
	if (processing) return
	processing = true
	while (true) {
		const headerEnd = buffer.indexOf('\r\n\r\n')
		if (headerEnd === -1) break

		const header = buffer.substring(0, headerEnd)
		const match = header.match(/Content-Length: (\d+)/i)
		if (!match) { buffer = buffer.substring(headerEnd + 4); continue }

		const len = parseInt(match[1], 10)
		const start = headerEnd + 4
		if (buffer.length < start + len) break

		const content = buffer.substring(start, start + len)
		buffer = buffer.substring(start + len)

		try {
			await handleMessage(JSON.parse(content))
		} catch (_) {}
	}
	processing = false
}

// --- Message handling ---

async function handleMessage(msg) {
	const { id, method, params } = msg

	if (method === 'initialize') {
		return send({ jsonrpc: '2.0', id, result: {
			protocolVersion: '2024-11-05',
			capabilities: { tools: {} },
			serverInfo: { name: 'aion', version: '1.0.0' }
		}})
	}

	// Notifications — no response
	if (!id) return

	if (method === 'tools/list') {
		return send({ jsonrpc: '2.0', id, result: { tools: TOOLS }})
	}

	if (method === 'tools/call') {
		const { name, arguments: args } = params
		try {
			if (name === 'display_set') {
				const ok = await callbackPost('agent-display', { url: args.url })
				send({ jsonrpc: '2.0', id, result: {
					content: [{ type: 'text', text: ok ? `Display set to: ${args.url}` : 'Failed to set display' }],
					isError: !ok
				}})
			} else if (name === 'display_clear') {
				const ok = await callbackPost('agent-display', { url: '' })
				send({ jsonrpc: '2.0', id, result: {
					content: [{ type: 'text', text: ok ? 'Display cleared' : 'Failed to clear display' }],
					isError: !ok
				}})
			} else {
				send({ jsonrpc: '2.0', id, error: { code: -32601, message: `Unknown tool: ${name}` }})
			}
		} catch (e) {
			send({ jsonrpc: '2.0', id, result: {
				content: [{ type: 'text', text: `Error: ${e.message}` }],
				isError: true
			}})
		}
		return
	}

	// Unknown method
	send({ jsonrpc: '2.0', id, error: { code: -32601, message: `Method not found: ${method}` }})
}

// --- HTTP callback to aion-server ---

async function callbackPost(endpoint, data) {
	if (!CALLBACK) return false
	try {
		const res = await fetch(`${CALLBACK}/internal/${endpoint}`, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({ ...data, token: TOKEN, sessionId: SESSION_ID })
		})
		return res.ok
	} catch (e) {
		process.stderr.write(`[aion-mcp] callback error: ${e.message}\n`)
		return false
	}
}
