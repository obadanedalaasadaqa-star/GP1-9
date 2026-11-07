const nodemailer = require('nodemailer');

// Gmail SMTP using an App Password (GMAIL_USER + GMAIL_APP_PASSWORD in .env).
// Without them, emails are not sent and the code is printed to the server log
// so verification can still be tested locally.
function isMailConfigured() {
  return Boolean(process.env.GMAIL_USER && process.env.GMAIL_APP_PASSWORD);
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

async function sendVerificationEmail(to, firstName, code) {
  if (!isMailConfigured()) {
    console.log(`[mail:dev] Verification code for ${to}: ${code}`);
    return;
  }

  await getTransporter().sendMail({
    from: `"Nexus" <${process.env.GMAIL_USER}>`,
    to,
    subject: `${code} is your Nexus verification code`,
    text:
      `Hi ${firstName},\n\n` +
      `Your Nexus verification code is: ${code}\n\n` +
      `It expires in 10 minutes. If you didn't create a Nexus account, ignore this email.`,
    html: `
      <div style="font-family:Arial,sans-serif;max-width:420px;margin:auto;padding:24px;
                  background:#08111E;color:#E8EEF7;border-radius:16px">
        <h2 style="margin:0 0 4px;color:#D6A046;letter-spacing:-0.5px">NEXUS</h2>
        <p style="margin:0 0 24px;color:#8A9BB4;font-size:13px">Smart Expense Tracking &amp; Loyalty</p>
        <p>Hi ${firstName},</p>
        <p>Your verification code is:</p>
        <p style="font-size:34px;font-weight:bold;letter-spacing:10px;color:#63D0C3;margin:16px 0">${code}</p>
        <p style="color:#8A9BB4;font-size:13px">It expires in 10 minutes.
          If you didn't create a Nexus account, you can ignore this email.</p>
      </div>`,
  });
}

module.exports = { isMailConfigured, sendVerificationEmail };
