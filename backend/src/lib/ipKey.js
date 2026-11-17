const net = require('net');

// Rate-limit key for an IP. One IPv6 user usually gets a whole /64, so IPv6
// addresses are grouped by their first 64 bits; otherwise a single phone could
// rotate through addresses and never hit a limit. IPv4 stays as it is.
function ipKey(ip) {
  if (typeof ip !== 'string' || ip === '') return 'unknown';
  const mapped = /^::ffff:(\d+\.\d+\.\d+\.\d+)$/i.exec(ip);
  if (mapped && net.isIPv4(mapped[1])) return mapped[1];
  if (net.isIPv4(ip)) return ip;

  const addr = ip.split('%')[0]; // drop a zone like fe80::1%en0
  if (!net.isIPv6(addr)) return ip;
  const [head, tail] = addr.includes('::') ? addr.split('::') : [addr, null];
  const left = head ? head.split(':') : [];
  const right = tail ? tail.split(':') : [];
  // An embedded IPv4 tail (a.b.c.d) is two hextets; only the first 4 matter here.
  const count = (parts) => parts.reduce((n, p) => n + (p.includes('.') ? 2 : 1), 0);
  const zeros = tail === null ? [] : Array(8 - count(left) - count(right)).fill('0');
  const hextets = [...left, ...zeros, ...right].slice(0, 4)
    .map((h) => (h.includes('.') ? '0' : h).toLowerCase().padStart(4, '0'));
  return `${hextets.join(':')}::/64`;
}

module.exports = { ipKey };
