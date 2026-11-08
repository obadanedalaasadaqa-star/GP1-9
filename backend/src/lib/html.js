// Escape a value for use inside HTML text or a quoted attribute.
// null/undefined become '', anything else is turned into a string first.
const HTML_ESCAPES = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };

function escapeHtml(value) {
  if (value == null) return '';
  return String(value).replace(/[&<>"']/g, (ch) => HTML_ESCAPES[ch]);
}

module.exports = { escapeHtml };
