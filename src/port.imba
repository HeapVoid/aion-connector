import {createServer} from 'net'

export const DEFAULT_MIN = 7700
export const DEFAULT_MAX = 7799

# Tries each port in [min, max] until a bind succeeds. Returns chosen port.
# Throws if none are free.
export def pickFreePort min = DEFAULT_MIN, max = DEFAULT_MAX
	let p = min
	while p <= max
		if await tryBind(p)
			return p
		p = p + 1
	throw new Error("no free port in {min}-{max}")

def tryBind p
	new Promise do(ok)
		const s = createServer!
		s.once('error', do ok(false))
		s.once('listening', do
			s.close do ok(true))
		s.listen(p, '0.0.0.0')
