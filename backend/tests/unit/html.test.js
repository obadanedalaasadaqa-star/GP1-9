const { escapeHtml } = require('../../src/lib/html');

describe('escapeHtml', () => {
  test('escapes & < > " \'', () => {
    expect(escapeHtml(`<a href="x">Tom & Jerry's</a>`))
      .toBe('&lt;a href=&quot;x&quot;&gt;Tom &amp; Jerry&#39;s&lt;/a&gt;');
  });

  test('null and undefined become an empty string', () => {
    expect(escapeHtml(null)).toBe('');
    expect(escapeHtml(undefined)).toBe('');
  });

  test('numbers are turned into strings', () => {
    expect(escapeHtml(12.5)).toBe('12.5');
    expect(escapeHtml(0)).toBe('0');
  });
});
