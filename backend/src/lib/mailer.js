const nodemailer = require('nodemailer');
const { escapeHtml } = require('./html');

// Email providers, picked on every send (so tests can change the env):
//   1. Brevo HTTPS API (BREVO_API_KEY + MAIL_FROM). Works on Render.
//   2. Gmail SMTP with an App Password (GMAIL_USER + GMAIL_APP_PASSWORD).
//      Local only: Render blocks outgoing SMTP.
//   3. Nothing set: dev mode. Emails are not sent; the code (or a one-line
//      receipt summary) is printed to the server log instead.
function mailProvider() {
  if (process.env.BREVO_API_KEY && process.env.MAIL_FROM) return 'brevo';
  if (process.env.GMAIL_USER && process.env.GMAIL_APP_PASSWORD) return 'gmail';
  return null;
}

function isMailConfigured() {
  return mailProvider() !== null;
}

const BREVO_URL = 'https://api.brevo.com/v3/smtp/email';

async function sendViaBrevo({ to, toName, subject, text, html }) {
  const res = await fetch(BREVO_URL, {
    method: 'POST',
    headers: {
      'api-key': process.env.BREVO_API_KEY,
      'content-type': 'application/json',
      accept: 'application/json',
    },
    body: JSON.stringify({
      sender: { name: process.env.MAIL_FROM_NAME || 'Nexus', email: process.env.MAIL_FROM },
      // Brevo answers 400 to an empty name, so leave it out when there is none.
      to: [{ email: to, ...(toName ? { name: toName } : {}) }],
      subject,
      textContent: text,
      htmlContent: html,
    }),
    signal: AbortSignal.timeout(10000),
  });
  if (!res.ok) {
    let message = res.statusText;
    try {
      const body = await res.json();
      if (body?.message) message = body.message;
    } catch { /* non-JSON error body */ }
    throw new Error(`Brevo ${res.status}: ${message}`);
  }
}

let transporter = null;
function getTransporter() {
  if (!transporter) {
    transporter = nodemailer.createTransport({
      service: 'gmail',
      auth: {
        user: process.env.GMAIL_USER,
        pass: process.env.GMAIL_APP_PASSWORD.replace(/\s/g, ''),
      },
    });
  }
  return transporter;
}

async function sendViaGmail({ to, subject, text, html }) {
  await getTransporter().sendMail({
    from: `"Nexus" <${process.env.GMAIL_USER}>`,
    to,
    subject,
    text,
    html,
  });
}

// Send through the configured provider. Callers handle dev mode first.
async function sendMail(message) {
  if (mailProvider() === 'brevo') return sendViaBrevo(message);
  return sendViaGmail(message);
}

// Shared dark Nexus card around the email body (body is already escaped HTML).
function card(body) {
  return `
      <div style="font-family:Arial,sans-serif;max-width:420px;margin:auto;padding:24px;
                  background:#08111E;color:#E8EEF7;border-radius:16px">
        <h2 style="margin:0 0 4px;color:#D6A046;letter-spacing:-0.5px">NEXUS</h2>
        <p style="margin:0 0 24px;color:#8A9BB4;font-size:13px">Smart Expense Tracking &amp; Loyalty</p>
        ${body}
      </div>`;
}

async function sendVerificationEmail(to, firstName, code) {
  if (!isMailConfigured()) {
    console.log(`[mail:dev] Verification code for ${to}: ${code}`);
    return;
  }

  await sendMail({
    to,
    toName: firstName,
    subject: `${code} is your Nexus verification code`,
    text:
      `Hi ${firstName},\n\n` +
      `Your Nexus verification code is: ${code}\n\n` +
      `It expires in 10 minutes. If you didn't create a Nexus account, ignore this email.`,
    html: card(`
        <p>Hi ${escapeHtml(firstName)},</p>
        <p>Your verification code is:</p>
        <p style="font-size:34px;font-weight:bold;letter-spacing:10px;color:#63D0C3;margin:16px 0">${escapeHtml(code)}</p>
        <p style="color:#8A9BB4;font-size:13px">It expires in 10 minutes.
          If you didn't create a Nexus account, you can ignore this email.</p>`),
  });
}

// Copy of a receipt a store sent. items are the saved strings ("Milk x2").
async function sendReceiptEmail(to, firstName, { storeName, items, totalAmount, pointsEarned, createdAt }) {
  const total = `${Number(totalAmount).toFixed(2)} JD`;
  if (!isMailConfigured()) {
    console.log(`[mail:dev] Receipt copy for ${to}: ${storeName}, ${total}, +${pointsEarned} pts`);
    return;
  }

  const date = new Date(createdAt ?? Date.now()).toUTCString();
  const lines = (items ?? []).map((item) => String(item));
  await sendMail({
    to,
    toName: firstName,
    subject: `Your receipt from ${storeName}: ${total}`,
    text:
      `Hi ${firstName},\n\n` +
      `Your receipt from ${storeName} (${date}):\n` +
      lines.map((l) => `- ${l}`).join('\n') + '\n\n' +
      `Total: ${total}\nPoints earned: +${pointsEarned} pts\n\n` +
      `It is also saved in your Nexus Archive.`,
    html: card(`
        <p>Hi ${escapeHtml(firstName)},</p>
        <p>Your receipt from <strong>${escapeHtml(storeName)}</strong></p>
        <p style="color:#8A9BB4;font-size:12px;margin-top:-8px">${escapeHtml(date)}</p>
        <ul style="padding-left:18px;margin:16px 0">
          ${lines.map((l) => `<li>${escapeHtml(l)}</li>`).join('\n          ')}
        </ul>
        <p style="font-size:26px;font-weight:bold;color:#E8EEF7;margin:16px 0 4px">${escapeHtml(total)}</p>
        <p style="color:#63D0C3;font-weight:bold;margin:0 0 16px">+${escapeHtml(pointsEarned)} pts</p>
        <p style="color:#8A9BB4;font-size:13px">It is also saved in your Nexus Archive.</p>`),
  });
}

module.exports = { mailProvider, isMailConfigured, sendVerificationEmail, sendReceiptEmail };
