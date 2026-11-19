const net = require('net');

// Describes how a request reached the server (the proxy chain) without
// printing any IP address, so the right "trust proxy" setting can be read
// from the logs. Used once per process (see proxyCheckMiddleware).

const privateRanges = new net.BlockList();
privateRanges.addSubnet('10.0.0.0', 8, 'ipv4');
privateRanges.addSubnet('172.16.0.0', 12, 'ipv4');
privateRanges.addSubnet('192.168.0.0', 16, 'ipv4');
privateRanges.addSubnet('100.64.0.0', 10, 'ipv4'); // carrier-grade NAT
privateRanges.addSubnet('127.0.0.0', 8, 'ipv4');
privateRanges.addSubnet('169.254.0.0', 16, 'ipv4');
privateRanges.addSubnet('fc00::', 7, 'ipv6');
privateRanges.addSubnet('fe80::', 10, 'ipv6');
privateRanges.addAddress('::1', 'ipv6');

function clean(ip) {
  if (typeof ip !== 'string') return '';
  let s = ip.trim();
  const mapped = /^::ffff:(\d+\.\d+\.\d+\.\d+)$/i.exec(s);
  if (mapped) s = mapped[1];
  return s.split('%')[0];
}

// 'private', 'public' or 'invalid'. Never returns the address itself.
function ipKind(ip) {
  const s = clean(ip);
  const family = net.isIPv4(s) ? 'ipv4' : net.isIPv6(s) ? 'ipv6' : null;
  if (!family) return 'invalid';
  return privateRanges.check(s, family) ? 'private' : 'public';
}

// Where a single-IP header's value sits in X-Forwarded-For: 'absent',
// 'at:<index>' or 'not-in-xff'.
function headerPosition(value, xff) {
  if (typeof value !== 'string' || value.trim() === '') return 'absent';
  const i = xff.indexOf(clean(value));
  return i === -1 ? 'not-in-xff' : `at:${i}`;
}

function describeForwarding(req, trustSetting) {
  const raw = req.headers['x-forwarded-for'];
  const xff = (typeof raw === 'string' ? raw.split(',') : [])
    .map(clean).filter((s) => s !== '');
  return [
    '[proxy-check]',
    `xff=${xff.length}`,
    `kinds=${xff.length ? xff.map(ipKind).join(',') : '-'}`,
    `socket=${ipKind(req.socket && req.socket.remoteAddress)}`,
    `cf-connecting-ip=${headerPosition(req.headers['cf-connecting-ip'], xff)}`,
    `true-client-ip=${headerPosition(req.headers['true-client-ip'], xff)}`,
    `x-real-ip=${headerPosition(req.headers['x-real-ip'], xff)}`,
    `trust=${JSON.stringify(trustSetting)}`,
    `req.ip=${ipKind(req.ip)}`,
  ].join(' ');
}

// Logs describeForwarding() for the first request this app sees, then never
// again. log is injectable for tests.
function proxyCheckMiddleware(trustSetting, log = console.log) {
  let done = false;
  return (req, _res, next) => {
    if (!done) {
      done = true;
      try { log(describeForwarding(req, trustSetting)); } catch { /* never block a request */ }
    }
    next();
  };
}

module.exports = { ipKind, describeForwarding, proxyCheckMiddleware };
