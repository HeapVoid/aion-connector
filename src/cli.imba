#!/usr/bin/env bun
import {Connector} from './connector.imba'
import {log, error} from './utils.imba'
import {existsSync} from 'fs'

# Find config file
const configPath = process.argv[2] or "./aion.config.json"

unless existsSync(configPath)
	console.error "Config file not found: {configPath}"
	console.error ""
	console.error "Usage: aion-connector [config-path]"
	console.error "  Default: ./aion.config.json"
	console.error ""
	console.error "Config format:"
	console.error '  \{'
	console.error '    "port": 7777,'
	console.error '    "projects": \{'
	console.error '      "PROJECT_ID": \{'
	console.error '        "token": "secret",'
	console.error '        "dir": "./projects/name",'
	console.error '        "agents": \{'
	console.error '          "qwen": \{ "description": "Qwen 3 Coder" \}'
	console.error '        \}'
	console.error '      \}'
	console.error '    \}'
	console.error '  \}'
	process.exit(1)

let config
try
	const file = Bun.file(configPath)
	config = await file.json!
catch e
	error "Failed to parse config: {e.message}"
	process.exit(1)

unless config.projects and Object.keys(config.projects).length
	error "Config must have at least one project"
	process.exit(1)

const connector = new Connector(config)
await connector.start!
