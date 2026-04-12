import {resolve} from 'path'
import {spawn} from 'child_process'

const DENY = [".env", ".git", ".pem", ".key", "credentials", ".secret"]

export def sanitize dir, rel
	const abs = resolve(dir, rel)
	unless abs.startsWith(dir)
		throw new Error("path traversal")
	abs

export def denied path
	DENY.some do(p) path.includes(p)

export def log ...args
	console.log("[aion-connector]", ...args)

export def error ...args
	console.error("[aion-connector]", ...args)

# Spawn a process, collect stdout/stderr, return {stdout, stderr, exitCode}
export def exec args, opts = {}
	new Promise do(ok)
		const proc = spawn(args[0], args.slice(1), { ...opts, stdio: ['pipe', 'pipe', 'pipe'] })
		let stdout = ''
		let stderr = ''
		proc.stdout.on('data', do(chunk) stdout += chunk.toString!)
		proc.stderr.on('data', do(chunk) stderr += chunk.toString!)
		proc.on('close', do(code)
			ok({ stdout, stderr, exitCode: code })
		)
