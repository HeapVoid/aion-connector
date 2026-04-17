import {exec, sha256Hex} from './utils.imba'
import {writeFileSync, readFileSync, chmodSync, mkdirSync, existsSync} from 'fs'
import {dirname} from 'path'

# Generate a self-signed RSA 2048 cert valid 10 years for CN=aion-connector.
# Writes cert.pem and key.pem with mode 600. Returns SHA-256 fingerprint (lowercase hex, 64 chars).
export def generateSelfSigned certPath, keyPath
	mkdirSync(dirname(certPath), { recursive: yes })
	const r = await exec [
		'openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes'
		'-keyout', keyPath
		'-out', certPath
		'-days', '3650'
		'-subj', '/CN=aion-connector'
	]
	if r.exitCode != 0
		throw new Error("openssl req failed: {r.stderr}")
	chmodSync(certPath, 0o600)
	chmodSync(keyPath, 0o600)
	await fingerprint(certPath)

# SHA-256 fingerprint of cert (lowercase hex, 64 chars). Matches what Node's tls peer cert reports.
export def fingerprint certPath
	const f = await exec(['openssl', 'x509', '-in', certPath, '-noout', '-fingerprint', '-sha256'])
	if f.exitCode != 0
		throw new Error("openssl x509 -fingerprint failed: {f.stderr}")
	# openssl output: "sha256 Fingerprint=AA:BB:CC:..."
	const hex = f.stdout.split('=')[1]..trim!.replace(/:/g, '').toLowerCase!
	unless hex and hex.length == 64
		throw new Error("unexpected fingerprint output: {f.stdout}")
	hex

export def loadCertKey certPath, keyPath
	{ cert: readFileSync(certPath), key: readFileSync(keyPath) }
