import {resolve} from 'path'

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
