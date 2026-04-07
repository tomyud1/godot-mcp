/**
 * Tests for types module
 */

import { describe, it, expect } from 'vitest';
import type {
  WebSocketMessage,
  ToolInvokeMessage,
  ToolResultMessage,
  ClientStatusMessage
} from '../types.js';

describe('types module', () => {
  describe('WebSocketMessage', () => {
    it('should accept valid ping message', () => {
      const msg: WebSocketMessage = { type: 'ping' };
      expect(msg.type).toBe('ping');
    });

    it('should accept valid pong message', () => {
      const msg: WebSocketMessage = { type: 'pong' };
      expect(msg.type).toBe('pong');
    });

    it('should accept valid client_status message', () => {
      const msg: ClientStatusMessage = { type: 'client_status', count: 5 };
      expect(msg.type).toBe('client_status');
      expect(msg.count).toBe(5);
    });
  });

  describe('ToolInvokeMessage', () => {
    it('should accept valid tool invocation', () => {
      const msg: ToolInvokeMessage = {
        type: 'tool_invoke',
        id: 'test-id-123',
        tool: 'read_file',
        args: { path: '/test/path' },
      };
      expect(msg.type).toBe('tool_invoke');
      expect(msg.tool).toBe('read_file');
    });
  });

  describe('ToolResultMessage', () => {
    it('should accept successful result', () => {
      const msg: ToolResultMessage = {
        type: 'tool_result',
        id: 'test-id-123',
        success: true,
        result: { content: 'test' },
      };
      expect(msg.type).toBe('tool_result');
      expect(msg.success).toBe(true);
    });

    it('should accept error result', () => {
      const msg: ToolResultMessage = {
        type: 'tool_result',
        id: 'test-id-123',
        success: false,
        error: 'Test error',
      };
      expect(msg.type).toBe('tool_result');
      expect(msg.success).toBe(false);
      expect(msg.error).toBe('Test error');
    });
  });
});
