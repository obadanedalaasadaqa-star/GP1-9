const { Server } = require('socket.io');
const { verifySession } = require('./token');

// Live push to the app. Each phone joins the room "user:<id>" with its JWT,
// and the server only pushes (receipt:new). Phones never send events.
let io = null;

const MAX_TIMEOUT_MS = 2 ** 31 - 1; // setTimeout limit (~24.8 days)

function initRealtime(httpServer) {
  io = new Server(httpServer, { cors: { origin: '*' } });

  io.use((socket, next) => {
    const s = verifySession(socket.handshake.auth?.token); // same rule as authMiddleware
    if (!s) return next(new Error('unauthorized'));
    socket.data.userId = s.userId;
    socket.data.exp = s.exp;
    next();
  });

  io.on('connection', (socket) => {
    socket.join(`user:${socket.data.userId}`);

    // Drop the socket when its token expires. The client gets
    // "io server disconnect" (no auto-reconnect); the app reconnects once by
    // hand, that handshake fails with "unauthorized", and the app logs out.
    if (socket.data.exp) {
      const ms = Math.min(socket.data.exp * 1000 - Date.now(), MAX_TIMEOUT_MS);
      const timer = setTimeout(() => socket.disconnect(true), Math.max(ms, 0));
      socket.on('disconnect', () => clearTimeout(timer));
    }
  });

  return io;
}

// Push [event] to every socket of [userId]. No-op if initRealtime() was never
// called (e.g. Supertest tests on a plain createApp()).
function emitToUser(userId, event, payload) {
  io?.to(`user:${userId}`).emit(event, payload);
}

// For tests: close the server and forget it.
function closeRealtime() {
  return new Promise((resolve) => {
    if (!io) return resolve();
    const current = io;
    io = null;
    current.close(() => resolve());
  });
}

module.exports = { initRealtime, emitToUser, closeRealtime };
