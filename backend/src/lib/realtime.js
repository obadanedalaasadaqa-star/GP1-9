const { Server } = require('socket.io');
const { loadSession, sessionIsCurrent } = require('./session');

// Live push to the app. Each phone joins the room "user:<id>" with its JWT,
// and the server only pushes (receipt:new). Phones never send events.
let io = null;

const MAX_TIMEOUT_MS = 2 ** 31 - 1; // setTimeout limit (~24.8 days)

function initRealtime(httpServer) {
  io = new Server(httpServer, { cors: { origin: '*' } });

  // Same rule as authMiddleware. Only 'unauthorized' makes the app log out;
  // on a DB error it keeps reconnecting.
  io.use(async (socket, next) => {
    let s;
    try {
      s = await loadSession(socket.handshake.auth?.token);
    } catch (err) {
      console.error('[realtime] session check', err.message);
      return next(new Error('unavailable'));
    }
    if (!s) return next(new Error('unauthorized'));
    socket.data.userId = s.userId;
    socket.data.exp = s.exp;
    socket.data.tv = s.tv;
    next();
  });

  io.on('connection', (socket) => {
    socket.join(`user:${socket.data.userId}`);

    // A session ended (disconnectUser) between the handshake's check and the
    // join above would leave this socket in the room. Check the version once
    // more now that it is in: a later disconnectUser reaches it, an earlier one
    // shows here. (Expiry is left to the timer below.)
    sessionIsCurrent(socket.data.userId, socket.data.tv)
      .then((current) => { if (!current) socket.disconnect(true); })
      .catch(() => {}); // DB blip: keep it (the handshake already passed)

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

// Drop every open socket of [userId] (their session just ended). The app
// reconnects once, the handshake is refused, and that phone logs out. No-op
// without initRealtime(), like emitToUser.
function disconnectUser(userId) {
  io?.in(`user:${userId}`).disconnectSockets(true);
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

module.exports = { initRealtime, emitToUser, disconnectUser, closeRealtime };
