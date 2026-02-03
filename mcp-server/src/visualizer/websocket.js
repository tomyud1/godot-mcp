/**
 * WebSocket connection for real-time communication with Godot
 */

let ws = null;
let wsConnected = false;
const pendingRequests = new Map();
let requestId = 0;

export function connectWebSocket() {
  const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
  ws = new WebSocket(`${protocol}//${window.location.host}`);

  ws.onopen = () => {
    wsConnected = true;
    console.log('[visualizer] WebSocket connected');
  };

  ws.onclose = () => {
    wsConnected = false;
    console.log('[visualizer] WebSocket disconnected, reconnecting...');
    setTimeout(connectWebSocket, 2000);
  };

  ws.onerror = (err) => {
    console.error('[visualizer] WebSocket error:', err);
  };

  ws.onmessage = (event) => {
    try {
      const msg = JSON.parse(event.data);
      if (msg.id && pendingRequests.has(msg.id)) {
        const { resolve, reject } = pendingRequests.get(msg.id);
        pendingRequests.delete(msg.id);
        if (msg.error) {
          reject(new Error(msg.error));
        } else {
          resolve(msg.result || msg);
        }
      }
    } catch (err) {
      console.error('[visualizer] Failed to parse message:', err);
    }
  };
}

export function sendCommand(command, args) {
  return new Promise((resolve, reject) => {
    if (!wsConnected || !ws) {
      reject(new Error('WebSocket not connected'));
      return;
    }

    const id = ++requestId;
    pendingRequests.set(id, { resolve, reject });

    ws.send(JSON.stringify({
      type: 'visualizer_command',
      id,
      command,
      args
    }));

    // Timeout after 30 seconds
    setTimeout(() => {
      if (pendingRequests.has(id)) {
        pendingRequests.delete(id);
        reject(new Error('Request timeout'));
      }
    }, 30000);
  });
}

export function isConnected() {
  return wsConnected;
}
