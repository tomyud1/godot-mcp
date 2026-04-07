/**
 * Tests for GodotBridge class
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { createBridge } from '../godot-bridge.js';

describe('GodotBridge', () => {
  let bridge: ReturnType<typeof createBridge>;
  const TEST_PORT = 16505; // Use non-standard port for tests
  const TEST_TIMEOUT = 5000;

  beforeEach(() => {
    bridge = createBridge(TEST_PORT, TEST_TIMEOUT);
    vi.clearAllMocks();
  });

  afterEach(() => {
    try {
      bridge.stop();
    } catch {
      // Ignore errors during cleanup
    }
  });

  describe('constructor', () => {
    it('should create a bridge with default port and timeout', () => {
      const defaultBridge = createBridge();
      expect(defaultBridge).toBeDefined();
    });

    it('should create a bridge with custom port and timeout', () => {
      const customBridge = createBridge(9999, 1000);
      expect(customBridge).toBeDefined();
    });

    it('should have getStatus method', () => {
      const status = bridge.getStatus();
      expect(status).toHaveProperty('port');
      expect(status).toHaveProperty('connected');
      expect(status).toHaveProperty('pendingRequests');
      expect(status.port).toBe(TEST_PORT);
    });
  });

  describe('getStatus', () => {
    it('should return status object with correct structure', () => {
      const status = bridge.getStatus();
      expect(typeof status.connected).toBe('boolean');
      expect(typeof status.pendingRequests).toBe('number');
      expect(typeof status.port).toBe('number');
      expect(status.port).toBe(TEST_PORT);
      expect(status.pendingRequests).toBe(0);
    });

    it('should have projectPath and connectedAt fields', () => {
      const status = bridge.getStatus();
      expect(status).toHaveProperty('projectPath');
      expect(status).toHaveProperty('connectedAt');
    });
  });

  describe('onConnectionChange and offConnectionChange', () => {
    it('should register connection change callback', () => {
      const callback = vi.fn();
      expect(() => bridge.onConnectionChange(callback)).not.toThrow();
    });

    it('should unregister connection change callback', () => {
      const callback = vi.fn();
      bridge.onConnectionChange(callback);
      expect(() => bridge.offConnectionChange(callback)).not.toThrow();
    });
  });

  describe('stop', () => {
    it('should stop without errors', () => {
      expect(() => bridge.stop()).not.toThrow();
    });

    it('should be idempotent', () => {
      expect(() => {
        bridge.stop();
        bridge.stop();
        bridge.stop();
      }).not.toThrow();
    });
  });
});
