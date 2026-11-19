const express = require('express');
const request = require('supertest');
const { ipKind, describeForwarding, proxyCheckMiddleware } = require('../../src/lib/proxyCheck');

function fakeReq(headers = {}, remoteAddress = '10.0.0.5', ip = '10.0.0.5') {
  return { headers, socket: { remoteAddress }, ip };
}

describe('ipKind', () => {
  test.each([
    ['10.29.117.13', 'private'], ['172.20.1.1', 'private'], ['192.168.1.9', 'private'],
    ['100.64.0.1', 'private'], ['127.0.0.1', 'private'], ['::1', 'private'],
    ['::ffff:10.1.2.3', 'private'], ['fd12::1', 'private'], ['fe80::1%en0', 'private'],
    ['8.8.8.8', 'public'], ['104.16.0.1', 'public'], ['2001:4860::8888', 'public'],
    ['', 'invalid'], ['nonsense', 'invalid'], [undefined, 'invalid'],
  ])('%s → %s', (ip, kind) => expect(ipKind(ip)).toBe(kind));
});

describe('describeForwarding', () => {
  const xff = '203.0.113.7, 104.16.0.1, 10.29.117.13';
  const ADDRESSES = ['203.0.113.7', '104.16.0.1', '10.29.117.13', '10.0.0.5'];

  test('shows the chain shape and header positions', () => {
    const line = describeForwarding(fakeReq({
      'x-forwarded-for': xff,
      'cf-connecting-ip': '203.0.113.7',
      'true-client-ip': '198.51.100.1',
    }), 1);
    expect(line).toBe('[proxy-check] xff=3 kinds=public,public,private socket=private ' +
      'cf-connecting-ip=at:0 true-client-ip=not-in-xff x-real-ip=absent trust=1 req.ip=private');
  });

  test('never prints an IP address', () => {
    const line = describeForwarding(fakeReq({
      'x-forwarded-for': xff, 'cf-connecting-ip': '203.0.113.7', 'x-real-ip': '104.16.0.1',
    }), 'loopback');
    for (const a of ADDRESSES) expect(line).not.toContain(a);
    expect(line).toContain('trust="loopback"');
  });

  test('no forwarding headers', () => {
    expect(describeForwarding(fakeReq({}), 1)).toBe('[proxy-check] xff=0 kinds=- socket=private ' +
      'cf-connecting-ip=absent true-client-ip=absent x-real-ip=absent trust=1 req.ip=private');
  });

  test('a strange header value cannot break the line', () => {
    const line = describeForwarding(fakeReq({ 'x-forwarded-for': ' , garbage,,8.8.8.8 ' }), 2);
    expect(line).toContain('xff=2 kinds=invalid,public');
  });
});

describe('proxyCheckMiddleware', () => {
  test('logs only the first request, and every request still goes through', async () => {
    const log = jest.fn();
    const app = express();
    app.set('trust proxy', 1);
    app.use(proxyCheckMiddleware(1, log));
    app.get('/x', (req, res) => res.json({ ok: true }));
    for (let i = 0; i < 3; i++) {
      const res = await request(app).get('/x').set('X-Forwarded-For', '203.0.113.7');
      expect(res.status).toBe(200);
    }
    expect(log).toHaveBeenCalledTimes(1);
    expect(log.mock.calls[0][0]).toMatch(/^\[proxy-check\] xff=1 kinds=public /);
    expect(log.mock.calls[0][0]).not.toContain('203.0.113.7');
  });

  test('skips requests without X-Forwarded-For, then logs the first proxied one', async () => {
    const log = jest.fn();
    const app = express();
    app.use(proxyCheckMiddleware(1, log));
    app.get('/x', (req, res) => res.json({ ok: true }));
    expect((await request(app).get('/x')).status).toBe(200);
    expect((await request(app).get('/x')).status).toBe(200);
    expect(log).not.toHaveBeenCalled();
    await request(app).get('/x').set('X-Forwarded-For', '203.0.113.7, 10.0.0.1');
    await request(app).get('/x').set('X-Forwarded-For', '198.51.100.2');
    expect(log).toHaveBeenCalledTimes(1);
    expect(log.mock.calls[0][0]).toMatch(/xff=2 kinds=public,private /);
  });

  test('a throwing logger never blocks the request', async () => {
    const app = express();
    app.use(proxyCheckMiddleware(1, () => { throw new Error('boom'); }));
    app.get('/x', (req, res) => res.json({ ok: true }));
    expect((await request(app).get('/x').set('X-Forwarded-For', '8.8.8.8')).status).toBe(200);
  });
});
