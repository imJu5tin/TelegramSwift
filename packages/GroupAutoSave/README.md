# GroupAutoSave

A Swift package that exposes your running Telegram for macOS client to an external agent (Claude Code, Claude Desktop, etc.) over the [Model Context Protocol](https://modelcontextprotocol.io/). The agent can list your chats, walk message history, follow `t.me/...` links across groups, and archive media to disk — all driven by prompts, not a hard-coded UI.

The package contains five library targets:

| Target | Purpose |
|---|---|
| `MessageInspector` | Pure-logic helpers: extract qualifying media (photo/non-GIF video) and outgoing URLs from a `Message`. |
| `PeerLinkResolver` | Parse `t.me/<user>/<id>` and `t.me/c/<chan>/<id>` URLs; resolve to `(Peer, Message)` via the Telegram engine. |
| `MediaArchiver` | Lay out files at `~/Downloads/TelegramAutoSave/<peer>/<msg-or-album>/`; collision suffixing; skipped-link log. |
| `MessageWalker` | Wrap `searchMessages` (history) and `notificationMessages` (live) behind a protocol; LRU dedup cache. |
| `MCPServer` | Minimal HTTP+JSON-RPC MCP server (`NWListener`-based). Bearer-token auth. |

The Mac app target adds a thin `MCPRunner` and a `MCPTools.swift` that registers six tools backed by these modules:

- `list_dialogs(limit)` — chats the active account participates in
- `walk_history(peer_id, session_id, limit)` — paginate a chat newest→oldest with a server-side cursor keyed by `session_id`
- `inspect_message(peer_id, message_id)` — extract qualifying media + outgoing URLs from a single message
- `resolve_tme_link(url)` — parse + resolve a t.me link to its destination peer + message
- `archive_message(peer_id, message_id, peer_title, follow_links?)` — download media for a single message (and, by default, follow t.me links and archive their media into the same folder); returns saved file paths and skipped-link reasons
- `get_new_messages_since(peer_id, after_message_id, limit)` — poll for messages newer than a given id

## Endpoint and auth

When the Mac app launches and signs in, the runner starts the server on `http://127.0.0.1:7777/mcp` (or the next available port). Two files are written to `~/.config/telegram-archive-mcp/`:

- `token` — the bearer token, mode `0600`. Send it as `Authorization: Bearer <token>`.
- `endpoint` — the URL the server is currently listening on (useful when the preferred port was taken).

The token persists across launches; delete the file to rotate.

## Connecting from Claude Code

Add to `~/.claude/mcp_servers.json` (or your project's `.mcp.json`):

```json
{
  "mcpServers": {
    "telegram-archive": {
      "transport": "http",
      "url": "http://127.0.0.1:7777/mcp",
      "headers": {
        "Authorization": "Bearer YOUR_TOKEN_HERE"
      }
    }
  }
}
```

Replace `YOUR_TOKEN_HERE` with the contents of `~/.config/telegram-archive-mcp/token`.

Then in a Claude Code session, the tools appear under the `telegram-archive` namespace.

## Example agent prompts

```
List my dialogs and find the group titled "Lectures".
Walk that group's history. For each message, archive it (with follow_links).
After ~50 messages or no more available, summarize:
- How many media files saved
- How many cross-chat links followed
- Any skipped reasons
```

Or to watch a single group in near-real-time, polling every minute:

```
Every 60 seconds for the next hour, call get_new_messages_since(peer_id=<id>,
after_message_id=<latest known>) and archive any new messages with media.
```

## Running tests

The unit tests cover all pure-logic helpers (URL parsing, folder/filename sanitization, media-type filtering, dedup cache, JSON-RPC encoding, MCP handler dispatch, bearer-token utilities):

```bash
cd packages/GroupAutoSave
swift test
```

## Limitations / things to know

- **Sandbox**: the Mac app's main configuration disables sandboxing; the App Store entitlements (`Telegram-Sandbox.entitlements`) include `com.apple.security.network.server`. Both can listen on localhost.
- **No SSE streaming**: live message subscription is poll-based via `get_new_messages_since`. Streaming may be added later.
- **No automatic cross-link recursion beyond depth 1**: `archive_message` follows t.me links once. The agent itself is free to call `archive_message` again on the linked message if you want deeper chains.
- **Inaccessible private channels** are reported via the `skipped` array in `archive_message` results and logged to `~/Downloads/TelegramAutoSave/<peer>/skipped.txt`.
- **Privacy**: every message body, media metadata, and link the agent inspects flows over the localhost MCP connection to whatever LLM client you've configured. The bearer token only protects against other local processes — your LLM client sees everything you ask the agent to look at.
