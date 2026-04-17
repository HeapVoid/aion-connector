# Workspace state: workspace.json + tls/{cert,key}.pem under $HOME/.config/aion-connector/
import {existsSync, mkdirSync, readFileSync, writeFileSync, chmodSync} from 'fs'
import {join, dirname} from 'path'
import {homedir} from 'os'

export def stateDir base = null
	const h = base or homedir!
	join(h, '.config', 'aion-connector')

export def statePath base = null
	join(stateDir(base), 'workspace.json')

export def tlsDir base = null
	join(stateDir(base), 'tls')

export def certPath base = null
	join(tlsDir(base), 'cert.pem')

export def keyPath base = null
	join(tlsDir(base), 'key.pem')

export def ensureDirs base = null
	const d = stateDir(base)
	mkdirSync(d, {recursive: yes, mode: 0o700})
	const t = tlsDir(base)
	mkdirSync(t, {recursive: yes, mode: 0o700})

export def readState base = null
	const p = statePath(base)
	return null unless existsSync(p)
	JSON.parse(readFileSync(p, 'utf8'))

export def writeState data, base = null
	ensureDirs(base)
	const p = statePath(base)
	writeFileSync(p, JSON.stringify(data, null, 2))
	chmodSync(p, 0o600)

export def mergeState patch, base = null
	const cur = readState(base) or {}
	const next = Object.assign({}, cur, patch)
	writeState(next, base)
	next
