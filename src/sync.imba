# Two-way sync of coordinator/ files. Each file carries a SHA-256 content hash.
# On push from AION, a provided `expected_prev_hash` is matched against the current
# on-disk hash; mismatch → ConflictError. Caller maps this to HTTP 409.
import {readFileSync, writeFileSync, existsSync, mkdirSync, readdirSync, chmodSync, unlinkSync} from 'fs'
import {join, dirname} from 'path'
import {sha256Hex} from './utils.imba'

export class ConflictError < Error
	def constructor path, actualHash
		super "sync conflict at {path}: on-disk hash is {actualHash}"
		self.path = path
		self.actualHash = actualHash

export def coordinatorDir home
	join(home, 'coordinator')

export def personaPath home
	join(coordinatorDir(home), 'persona.md')

export def skillsDir home
	join(coordinatorDir(home), 'skills')

export def skillPath home, name
	join(skillsDir(home), "{name}.md")

export def hashFile path
	return null unless existsSync(path)
	sha256Hex(readFileSync(path))

# Read file. Returns {content, hash} or null if missing.
export def readFile path
	return null unless existsSync(path)
	const content = readFileSync(path, 'utf8')
	{ content, hash: sha256Hex(content) }

# Write file with conflict check. If expectedPrevHash is provided and does not match
# the current on-disk hash, throws ConflictError. If file doesn't exist, expectedPrevHash
# must be null (or omitted).
export def writeFile path, content, expectedPrevHash = undefined, mode = 0o600
	const actual = hashFile(path)
	if expectedPrevHash !== undefined and expectedPrevHash !== actual
		throw new ConflictError(path, actual)
	mkdirSync(dirname(path), { recursive: yes })
	writeFileSync(path, content)
	chmodSync(path, mode)
	sha256Hex(content)

# List current skill files → [{ name, hash, content }].
export def listSkills home
	const d = skillsDir(home)
	return [] unless existsSync(d)
	const files = readdirSync(d).filter(do(f) f.endsWith('.md'))
	files.map do(f)
		const name = f.slice(0, -3)
		const r = readFile(join(d, f))
		{ name, content: r.content, hash: r.hash }

# Overwrite skills directory to exactly match `skills = [{name, content}]`.
# Returns [{name, hash}].
export def writeSkills home, skills
	const d = skillsDir(home)
	mkdirSync(d, { recursive: yes })
	const keep = new Set(skills.map(do(s) "{s.name}.md"))
	const existing = readdirSync(d).filter(do(f) f.endsWith('.md'))
	for f in existing
		unless keep.has(f)
			unlinkSync(join(d, f))
	skills.map do(s)
		writeFile(skillPath(home, s.name), s.content, undefined, 0o600)
		{ name: s.name, hash: sha256Hex(s.content) }
