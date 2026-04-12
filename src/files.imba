import {resolve, relative} from 'path'
import {existsSync, readFileSync, statSync} from 'fs'
import {sanitize, denied, exec} from './utils.imba'

export class Files
	#repos

	def constructor repos
		#repos = repos

	def tree payload
		const dir = #repos.resolve(payload.workspace)
		return { error: "no workspace" } unless dir
		const rel = payload.path or "."
		const out = await git(dir, "ls-files", "--cached", "--others", "--exclude-standard")
		const lines = out.split("\n").filter(Boolean)
		const filtered = lines.filter do(l) !denied(l)

		# Build nested tree from flat paths
		const root = []
		const dirs = {}
		for p in filtered
			const parts = p.split('/')
			let parent = root
			let current = ''
			for part, idx in parts
				current = current ? "{current}/{part}" : part
				if idx == parts.length - 1
					parent.push({ name: part, type: 'file', path: p })
				else
					unless dirs[current]
						const node = { name: part, type: 'dir', path: current, children: [] }
						dirs[current] = node
						parent.push(node)
					parent = dirs[current].children

		# Sort: dirs first, then files, alphabetically
		sortTree(root)
		{ tree: root, root: rel }

	def sortTree arr
		arr.sort do(a, b)
			if a.type != b.type
				return a.type == 'dir' ? -1 : 1
			a.name < b.name ? -1 : 1
		for item in arr
			if item.children
				sortTree(item.children)

	def read payload
		const dir = #repos.resolve(payload.workspace)
		return { error: "no workspace" } unless dir
		const abs = sanitize(dir, payload.path)
		if denied(payload.path)
			return { error: "denied" }
		unless existsSync(abs)
			return { error: "not found" }
		const stat = statSync(abs)
		const size = stat.size
		if size > 1_000_000
			return { path: payload.path, size, binary: yes, truncated: yes }
		const content = readFileSync(abs, 'utf8')
		{ path: payload.path, content, size, binary: no }

	def status payload
		const dir = #repos.resolve(payload.workspace)
		return { error: "no workspace" } unless dir
		const out = await git(dir, "status", "--porcelain")
		const lines = out.split("\n").filter(Boolean)
		lines.map do(line)
			{ status: line.slice(0, 2).trim!, path: line.slice(3) }

	def diff payload
		const dir = #repos.resolve(payload.workspace)
		return { error: "no workspace" } unless dir
		const args = ["diff"]
		if payload.paths
			args.push("--", ...payload.paths)
		const out = await git(dir, ...args)
		{ diff: out }

	def git dir, ...args
		const result = await exec(["git", ...args], cwd: dir)
		result.stdout.trim!
