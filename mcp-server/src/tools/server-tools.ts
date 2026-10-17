/**
 * Tools answered by the server itself (never forwarded to Godot). Defined
 * here so they are listed and argument-checked like every other tool.
 */

import type { ToolDefinition } from '../types.js';
import { GUIDES } from '../resources.js';

export const serverTools: ToolDefinition[] = [
  {
    name: 'get_godot_status',
    description: 'Check if the Godot editor is connected to the MCP server. Also reports the plugin, server and Godot versions, and warns when the plugin and server versions differ.',
    inputSchema: { type: 'object', properties: {}, required: [] },
  },
  {
    name: 'get_guide',
    description: `Read a short markdown guide from the server. Same content as the MCP resources/read protocol, exposed as a tool so it works in MCP clients that do not support resources (e.g. Claude Desktop, Cursor chat). Call with no args to list available guides: ${GUIDES.map((g) => g.slug).join(', ')}. Call with {slug: "..."} to get the full markdown. Useful when a workflow is non-obvious (testing a running game, setting resources and property values, troubleshooting "Runtime helper not connected", etc.).`,
    inputSchema: {
      type: 'object',
      properties: {
        slug: {
          type: 'string',
          description: `Guide slug. Omit to list all available guides. Known slugs: ${GUIDES.map((g) => g.slug).join(', ')}.`,
        },
      },
      required: [],
    },
  },
];
