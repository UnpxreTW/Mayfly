//
//  NymphMCPShim
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import MCP

/// 契約 #31 五工具的 MCP `Tool` 目錄（`tools/list` 回傳的正本）——參數名故意跟 issue 契約的
/// snake_case 一致（`memory_gib` / `readiness_timeout_s` / `timeout_s` 等），不是 Swift 慣例的
/// camelCase：這層是 MCP 邊界、給 LLM 讀 schema，跟 ``NymphKit/NymphProtocol`` 的 Swift 型別
/// 各自服務各自的消費者，``NymphToolInvoker`` 是兩邊的轉接。
enum NymphToolCatalog {

	/// 依契約順序（spawn/execute/list/status/destroy）。
	static let tools: [Tool] = [spawn, execute, list, status, destroy]

	static let spawn = Tool(
		name: "spawn",
		description: """
		Spawn a disposable macOS VM cloned from a golden image. Blocks until the VM reports \
		READY by default; on a readiness timeout it degrades to state "booting" instead of \
		failing (poll with `status`). Returns an opaque session id, never a host path.
		""",
		inputSchema: [
			"type": "object",
			"properties": [
				"golden": [
					"type": "string",
					"description": "Golden image alias to clone from (an alias, not a host path).",
				],
				"cpus": [
					"type": "integer",
					"description": "Requested virtual CPU count, clamped to host limits.",
					"default": 4,
				],
				"memory_gib": [
					"type": "integer",
					"description": "Requested memory in GiB, clamped to host limits.",
					"default": 4,
				],
				"wait": [
					"type": "boolean",
					"description": "Block until READY. If false, return immediately with state \"booting\".",
					"default": true,
				],
				"readiness_timeout_s": [
					"type": "integer",
					"description": "Readiness wait ceiling in seconds (only applies when wait is true).",
					"default": 180,
				],
			],
			"required": ["golden"],
		]
	)

	static let execute = Tool(
		name: "execute",
		description: """
		Run a command inside an existing session over SSH. The remote command's exit code is \
		data, not an error — a non-zero exit is returned normally. This tool only fails (tool \
		error) when the command could not be delivered at all: unknown session id, the session \
		isn't ready yet, an SSH transport failure, or a timeout.
		""",
		inputSchema: [
			"type": "object",
			"properties": [
				"id": [
					"type": "string",
					"description": "Session id returned by spawn.",
				],
				"cmd": [
					"type": "array",
					"items": ["type": "string"],
					"description": "Remote command argv (non-empty).",
				],
				"timeout_s": [
					"type": "integer",
					"description": "Overall timeout in seconds; omit for no limit.",
				],
				"stdin": [
					"type": "string",
					"description": "Text to feed the remote command's stdin.",
				],
				"cwd": [
					"type": "string",
					"description": "Remote working directory to run the command from.",
				],
				"env": [
					"type": "object",
					"additionalProperties": ["type": "string"],
					"description": "Extra environment variables for the remote command.",
				],
			],
			"required": ["id", "cmd"],
		]
	)

	static let list = Tool(
		name: "list",
		description: """
		List sessions. By default only running sessions are listed; set all=true to include \
		stopped sessions that have not yet been reaped. An empty list is normal.
		""",
		inputSchema: [
			"type": "object",
			"properties": [
				"all": [
					"type": "boolean",
					"description": "Include stopped, unreaped sessions.",
					"default": false,
				],
			],
		]
	)

	static let status = Tool(
		name: "status",
		description: "Get the current status of a single session by id.",
		inputSchema: [
			"type": "object",
			"properties": [
				"id": [
					"type": "string",
					"description": "Session id returned by spawn.",
				],
			],
			"required": ["id"],
		]
	)

	static let destroy = Tool(
		name: "destroy",
		description: """
		Stop a session's VM and delete its disposable clone, removing it from the session \
		table. Safe to call again on an already-stopped, unreaped session (it just deletes \
		the clone).
		""",
		inputSchema: [
			"type": "object",
			"properties": [
				"id": [
					"type": "string",
					"description": "Session id returned by spawn.",
				],
				"force": [
					"type": "boolean",
					"description": "true = force stop immediately; false = graceful stop within a grace period.",
					"default": true,
				],
			],
			"required": ["id"],
		]
	)
}
