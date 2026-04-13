#!/usr/bin/env node

// AION MCP Server — tools for agents running in the AION platform
// Spawned by connector as stdio MCP server per agent session.
// Env: AION_CALLBACK, AION_TOKEN, AION_SESSION_ID
// Protocol: MCP stdio transport — newline-delimited JSON-RPC

const CALLBACK = process.env.AION_CALLBACK || ''
const TOKEN = process.env.AION_TOKEN || ''
const SESSION_ID = process.env.AION_SESSION_ID || ''

const { spawn } = require('child_process')

// Running background processes: pid → { proc, command, output (last N lines) }
const bgProcs = new Map()
const MAX_OUTPUT_LINES = 50

const TOOLS = [
	{
		name: 'run_background',
		description: 'Start a long-running process in the background (e.g. dev servers, watchers, builds). Returns immediately with a PID. The process keeps running after the tool returns. Use check_background to see its output later, and stop_background to stop it.',
		inputSchema: {
			type: 'object',
			properties: {
				command: { type: 'string', description: 'Shell command to run (e.g. "bun dev", "npm start", "python -m http.server 8080")' },
				cwd: { type: 'string', description: 'Working directory (optional, defaults to project root)' }
			},
			required: ['command']
		}
	},
	{
		name: 'check_background',
		description: 'Check status and recent output of a background process started with run_background.',
		inputSchema: {
			type: 'object',
			properties: {
				pid: { type: 'number', description: 'Process ID returned by run_background' }
			},
			required: ['pid']
		}
	},
	{
		name: 'stop_background',
		description: 'Stop a background process started with run_background.',
		inputSchema: {
			type: 'object',
			properties: {
				pid: { type: 'number', description: 'Process ID returned by run_background' }
			},
			required: ['pid']
		}
	},
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

// --- MCP stdio transport (newline-delimited JSON-RPC) ---

function send(msg) {
	process.stdout.write(JSON.stringify(msg) + '\n')
}

let buffer = ''
process.stdin.setEncoding('utf8')
process.stdin.on('data', chunk => {
	buffer += chunk
	const lines = buffer.split('\n')
	buffer = lines.pop() // keep incomplete last line
	for (const line of lines) {
		const trimmed = line.trim()
		if (!trimmed) continue
		try {
			handleMessage(JSON.parse(trimmed))
		} catch (_) {}
	}
})

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

	if (method === 'notifications/initialized') return

	// Notifications — no response
	if (!id) return

	if (method === 'tools/list') {
		return send({ jsonrpc: '2.0', id, result: { tools: TOOLS }})
	}

	if (method === 'tools/call') {
		const { name, arguments: args } = params
		try {
			if (name === 'run_background') {
				const cmd = args.command
				if (!cmd) {
					return send({ jsonrpc: '2.0', id, result: {
						content: [{ type: 'text', text: 'Error: command is required' }], isError: true
					}})
				}
				const proc = spawn('sh', ['-c', cmd], {
					cwd: args.cwd || process.cwd(),
					stdio: ['ignore', 'pipe', 'pipe'],
					detached: true
				})
				const pid = proc.pid
				const entry = { proc, command: cmd, output: [], running: true }
				bgProcs.set(pid, entry)

				const collect = (data) => {
					const lines = data.toString().split('\n').filter(l => l.trim())
					for (const line of lines) {
						entry.output.push(line)
						if (entry.output.length > MAX_OUTPUT_LINES) entry.output.shift()
					}
				}
				proc.stdout.on('data', collect)
				proc.stderr.on('data', collect)
				proc.on('close', (code) => {
					entry.running = false
					entry.exitCode = code
				})
				proc.unref()

				// Brief check — if process crashes, it crashes instantly
				await new Promise(resolve => setTimeout(resolve, 500))

				if (entry.running) {
					const output = entry.output.length ? `\n\nInitial output:\n${entry.output.join('\n')}` : ''
					send({ jsonrpc: '2.0', id, result: {
						content: [{ type: 'text', text: `Process running in background.\nPID: ${pid}\nCommand: ${cmd}${output}` }]
					}})
				} else {
					const output = entry.output.length ? `\n\nOutput:\n${entry.output.join('\n')}` : ''
					send({ jsonrpc: '2.0', id, result: {
						content: [{ type: 'text', text: `Process exited immediately with code ${entry.exitCode}.\nCommand: ${cmd}${output}\n\nThe process did not stay running. Check the command and try again.` }],
						isError: entry.exitCode !== 0
					}})
					bgProcs.delete(pid)
				}
			} else if (name === 'check_background') {
				const entry = bgProcs.get(args.pid)
				if (!entry) {
					return send({ jsonrpc: '2.0', id, result: {
						content: [{ type: 'text', text: `No background process with PID ${args.pid}` }], isError: true
					}})
				}
				const status = entry.running ? 'running' : `exited (code ${entry.exitCode})`
				const output = entry.output.length ? entry.output.join('\n') : '(no output yet)'
				send({ jsonrpc: '2.0', id, result: {
					content: [{ type: 'text', text: `PID: ${args.pid}\nStatus: ${status}\nCommand: ${entry.command}\n\nRecent output:\n${output}` }]
				}})
			} else if (name === 'stop_background') {
				const entry = bgProcs.get(args.pid)
				if (!entry) {
					return send({ jsonrpc: '2.0', id, result: {
						content: [{ type: 'text', text: `No background process with PID ${args.pid}` }], isError: true
					}})
				}
				try { process.kill(-args.pid) } catch (_) {
					try { entry.proc.kill() } catch (_) {}
				}
				bgProcs.delete(args.pid)
				send({ jsonrpc: '2.0', id, result: {
					content: [{ type: 'text', text: `Process ${args.pid} stopped.` }]
				}})
			} else if (name === 'display_set') {
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
