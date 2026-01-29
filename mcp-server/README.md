# Godot MCP Server

An MCP (Model Context Protocol) server that provides Godot game engine tools to AI assistants like Claude Desktop or RAGy.

## Features

- **File Operations**: List directories, read files, search project, create scripts
- **Scene Operations** (coming soon): Create/edit scenes, add/remove nodes
- **Script Operations** (coming soon): Apply code edits, validate scripts
- **Project Tools** (coming soon): Get project settings, input map, collision layers

## Installation

```bash
cd mcp-server
npm install
npm run build
```

## Usage

### With Claude Desktop

Add to your Claude Desktop config (`~/Library/Application Support/Claude/claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "godot": {
      "command": "node",
      "args": ["/Users/tomeryud/godot-mcp/mcp-server/dist/index.js"]
    }
  }
}
```

Then restart Claude Desktop.

### With RAGy

Add to RAGy's MCP client configuration (see RAGy documentation).

### Standalone Testing

Test with the MCP inspector:

```bash
npx @modelcontextprotocol/inspector node dist/index.js
```

## Development

```bash
# Watch mode (rebuild on changes)
npm run watch

# Build once
npm run build

# Run the server directly
npm start
```

## Architecture

```
mcp-server/
├── src/
│   ├── index.ts          # Main MCP server entry point
│   ├── types.ts          # TypeScript type definitions
│   ├── godot-bridge.ts   # WebSocket connection to Godot (Phase 2)
│   └── tools/
│       ├── index.ts      # Tool registry
│       ├── file-tools.ts # File operation tools
│       └── ...           # More tool categories
└── dist/                 # Compiled JavaScript
```

## Phases

1. **Phase 1 (Current)**: Mock tools - returns fake data for testing
2. **Phase 2**: WebSocket bridge - connects to Godot plugin
3. **Phase 3**: Godot plugin - executes tools in Godot editor
4. **Phase 4+**: Additional tools (scenes, scripts, etc.)

## License

MIT
