// lib/ipKey.js: rate-limit keys group IPv6 addresses by /64 (no server, no DB).
const { ipKey } = require('../../src/lib/ipKey');

test('IPv4 stays as it is', () => {
  expect(ipKey('203.0.113.7')).toBe('203.0.113.7');
});

test('an IPv4-mapped IPv6 address becomes the IPv4 address', () => {
  expect(ipKey('::ffff:203.0.113.7')).toBe('203.0.113.7');
  expect(ipKey('::FFFF:203.0.113.7')).toBe('203.0.113.7');
});

test('addresses in the same /64 share one key', () => {
  const a = ipKey('2001:db8:1:2:3:4:5:6');
  expect(a).toBe('2001:0db8:0001:0002::/64');
  expect(ipKey('2001:db8:1:2:ffff::1')).toBe(a);
  expect(ipKey('2001:DB8:1:2::a')).toBe(a);
});

test('another /64 gets another key', () => {
  expect(ipKey('2001:db8:1:3::1')).not.toBe(ipKey('2001:db8:1:2::1'));
});

test('a zone id is dropped', () => {
  expect(ipKey('fe80::1%en0')).toBe('fe80:0000:0000:0000::/64');
  expect(ipKey('fe80::1%en0')).toBe(ipKey('fe80::2'));
});

test('short forms like ::1 and :: work', () => {
  expect(ipKey('::1')).toBe('0000:0000:0000:0000::/64');
  expect(ipKey('::')).toBe('0000:0000:0000:0000::/64');
  expect(ipKey('2001:db8::')).toBe('2001:0db8:0000:0000::/64');
});

test.each([[undefined], [null], [''], [42]])('%p gives "unknown"', (ip) => {
  expect(ipKey(ip)).toBe('unknown');
});

test('a string that is not an IP is returned as given', () => {
  expect(ipKey('not-an-ip')).toBe('not-an-ip');
});
