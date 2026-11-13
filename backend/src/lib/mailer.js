const nodemailer = require('nodemailer');
const { escapeHtml } = require('./html');
const { formatAmount } = require('./aiFormat');
const { localDateOf } = require('./aiDates');

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

const AI_MISSING = 'The AI summary is not available for this report.';
const REPORT_FOOTER = 'The numbers are calculated by Nexus from your receipts. The summary is written by AI.';

// "New", "—" or "+12%" for the comparison line.
function reportChange(c) {
  if (c.changePercent === null) return c.isNew ? 'New' : '—';
  return c.changePercent > 0 ? `+${c.changePercent}%` : `${c.changePercent}%`;
}

// Spending report (routes/ai.js buildReport). Every dynamic string is escaped.
// tz: the user's offset in minutes, so receipt dates are their local dates.
async function sendReportEmail(to, firstName, report, tz = 0) {
  const { range, previous, totals, comparison, ai } = report;
  const jd = (n) => `${formatAmount(n)} JD`;
  const aiReady = ai?.status === 'ready';
  if (!isMailConfigured()) {
    console.log(`[mail:dev] Report for ${to}: ${range.label}, ${formatAmount(totals.total)} JD, AI ${ai?.status ?? 'none'}`);
    return;
  }

  const day = (iso) => localDateOf(iso, tz);
  const diff = `${comparison.difference > 0 ? '+' : ''}${jd(comparison.difference)}`;

  // Plain-text version with the same content.
  const textLines = [
    `Hi ${firstName},`, '',
    `Your Nexus spending report: ${range.label}`, '',
    ...(aiReady ? [ai.headline, '', ai.narrative, ''] : [AI_MISSING, '']),
    `Total: ${jd(totals.total)}`, `Receipts: ${totals.receipts}`, `Average receipt: ${jd(totals.average)}`, '',
    `Compared with ${previous.label}: ${jd(comparison.previousTotal)} (${diff}, ${reportChange(comparison)})`, '',
    'By category:',
    ...report.byCategory.map((c) => `- ${c.category}: ${jd(c.total)} (${c.sharePercent}%, ${c.receipts} receipts)`),
    '', 'By month:',
    ...report.byMonth.map((m) => `- ${m.label}${m.partial ? ' (so far)' : ''}: ${jd(m.total)} (${m.receipts} receipts)`),
    '', 'Top stores:',
    ...report.topStores.map((s) => `- ${s.storeName}: ${jd(s.total)} (${s.receipts} receipts)`),
    '', 'Biggest receipts:',
    ...report.biggestReceipts.map((b) => `- ${day(b.date)} ${b.storeName} (${b.category}): ${jd(b.total)}`),
    ...(aiReady ? ['', 'Tips:', ...ai.tips.map((t) => `- ${t}`)] : []),
    '', REPORT_FOOTER,
  ];

  const muted = 'color:#8A9BB4;font-size:13px';
  const h3 = (t) => `<h3 style="margin:20px 0 8px;color:#D6A046;font-size:15px">${escapeHtml(t)}</h3>`;
  const rows = (items) => `<table style="width:100%;border-collapse:collapse;font-size:13px">${items.map(([a, b]) =>
    `<tr><td style="padding:4px 0;color:#E8EEF7">${a}</td><td style="padding:4px 0;text-align:right;color:#E8EEF7">${b}</td></tr>`).join('')}</table>`;

  const html = card(`
        <p>Hi ${escapeHtml(firstName)},</p>
        <p style="margin:0 0 4px">Your spending report</p>
        <p style="${muted};margin-top:0">${escapeHtml(range.label)}</p>
        ${aiReady
    ? `<p style="font-size:17px;font-weight:bold;margin:16px 0 8px">${escapeHtml(ai.headline)}</p>
        <p style="line-height:1.5">${escapeHtml(ai.narrative)}</p>`
    : `<p style="${muted}">${escapeHtml(AI_MISSING)}</p>`}
        <p style="font-size:26px;font-weight:bold;margin:16px 0 4px">${escapeHtml(jd(totals.total))}</p>
        <p style="${muted};margin:0">${escapeHtml(totals.receipts)} receipts · average ${escapeHtml(jd(totals.average))}</p>
        ${h3(`Compared with ${previous.label}`)}
        <p style="margin:0">${escapeHtml(jd(comparison.previousTotal))} · ${escapeHtml(diff)} · ${escapeHtml(reportChange(comparison))}</p>
        ${h3('By category')}
        ${rows(report.byCategory.map((c) => [escapeHtml(c.category), `${escapeHtml(jd(c.total))} · ${escapeHtml(c.sharePercent)}%`]))}
        ${h3('By month')}
        ${rows(report.byMonth.map((m) => [`${escapeHtml(m.label)}${m.partial ? ' (so far)' : ''}`, escapeHtml(jd(m.total))]))}
        ${h3('Top stores')}
        ${rows(report.topStores.map((s) => [escapeHtml(s.storeName), escapeHtml(jd(s.total))]))}
        ${h3('Biggest receipts')}
        ${rows(report.biggestReceipts.map((b) => [`${escapeHtml(day(b.date))} · ${escapeHtml(b.storeName)} · ${escapeHtml(b.category)}`, escapeHtml(jd(b.total))]))}
        ${aiReady ? `${h3('Tips')}<ul style="padding-left:18px;margin:0">${ai.tips.map((t) => `<li>${escapeHtml(t)}</li>`).join('')}</ul>` : ''}
        <p style="${muted};margin-top:24px">${escapeHtml(REPORT_FOOTER)}</p>`);

  await sendMail({
    to,
    toName: firstName,
    subject: `Your Nexus spending report: ${range.label}`,
    text: textLines.join('\n'),
    html,
  });
}

const BUDGET_FOOTER = 'Change your budgets or turn these emails off in Nexus → Profile → Budgets & alerts.';

// Budget alert at 80% or 100% (lib/budgetAlerts.js). Every dynamic value is escaped.
async function sendBudgetAlertEmail(to, firstName, alert) {
  const { category, level, percent, spent, limit, remaining, overBy, monthLabel } = alert;
  const jd = (n) => `${formatAmount(n)} JD`;
  if (!isMailConfigured()) {
    console.log(`[mail:dev] Budget alert for ${to}: ${category} ${level}% (${formatAmount(spent)} / ${formatAmount(limit)} JD)`);
    return;
  }

  const subject = level >= 100
    ? `You're over your ${category} budget for ${monthLabel}`
    : `You've used ${percent}% of your ${category} budget`;
  const used = `${jd(spent)} of ${jd(limit)} used (${percent}%)`;
  const left = overBy > 0 ? `Over by ${jd(overBy)}` : `${jd(remaining)} left`;
  const color = level >= 100 ? '#F06A63' : '#D6A046';
  await sendMail({
    to,
    toName: firstName,
    subject,
    text:
      `Hi ${firstName},\n\n` +
      `${category} budget, ${monthLabel}:\n${used}\n${left}\n\n${BUDGET_FOOTER}`,
    html: card(`
        <p>Hi ${escapeHtml(firstName)},</p>
        <p style="margin:0 0 4px">Your <strong>${escapeHtml(category)}</strong> budget</p>
        <p style="color:#8A9BB4;font-size:13px;margin-top:0">${escapeHtml(monthLabel)}</p>
        <p style="font-size:26px;font-weight:bold;color:${color};margin:16px 0 4px">${escapeHtml(percent)}%</p>
        <p style="margin:0 0 4px">${escapeHtml(used)}</p>
        <p style="font-weight:bold;color:${color};margin:0 0 16px">${escapeHtml(left)}</p>
        <p style="color:#8A9BB4;font-size:13px">${escapeHtml(BUDGET_FOOTER)}</p>`),
  });
}

const WEEKLY_FOOTER = 'You get this because Weekly summary is on in Nexus → Profile.';

// "+12%", "-8%", "0%" or "—" (nothing the week before).
const weeklyChange = (p) => (p === null ? '—' : p > 0 ? `+${p}%` : `${p}%`);

// Weekly summary (lib/weeklyJob.js): numbers only, no AI text. Every dynamic
// value is escaped.
async function sendWeeklySummaryEmail(to, firstName, summary) {
  const jd = (n) => `${formatAmount(n)} JD`;
  if (!isMailConfigured()) {
    console.log(`[mail:dev] Weekly summary for ${to}: ${summary.label}, ${formatAmount(summary.total)} JD`);
    return;
  }

  const diff = `${summary.difference > 0 ? '+' : ''}${jd(summary.difference)}`;
  const change = `${diff} (${weeklyChange(summary.changePercent)}) vs the week before (${jd(summary.previousTotal)})`;
  const budgetLine = (b) => `${b.category} ${formatAmount(b.spent)} / ${formatAmount(b.limit)} JD (${b.percent}%)`;
  const textLines = [
    `Hi ${firstName},`, '',
    `Your Nexus week: ${summary.label}`, '',
    `Total: ${jd(summary.total)}`,
    `Receipts: ${summary.receipts} (average ${jd(summary.average)})`,
    `Change: ${change}`, '',
    'Top categories:',
    ...summary.topCategories.map((c) => `- ${c.category}: ${jd(c.total)}`),
    ...(summary.topStore ? ['', `Top store: ${summary.topStore.storeName} (${jd(summary.topStore.total)})`] : []),
    ...(summary.budgets.length ? ['', `Budgets this month (${summary.month}):`, ...summary.budgets.map((b) => `- ${budgetLine(b)}`)] : []),
    '', WEEKLY_FOOTER,
  ];

  const muted = 'color:#8A9BB4;font-size:13px';
  const h3 = (t) => `<h3 style="margin:20px 0 8px;color:#D6A046;font-size:15px">${escapeHtml(t)}</h3>`;
  const rows = (items) => `<table style="width:100%;border-collapse:collapse;font-size:13px">${items.map(([a, b]) =>
    `<tr><td style="padding:4px 0;color:#E8EEF7">${a}</td><td style="padding:4px 0;text-align:right;color:#E8EEF7">${b}</td></tr>`).join('')}</table>`;
  const budgetColor = (b) => (b.level === 'over' ? '#F06A63' : b.level === 'warning' ? '#D6A046' : '#E8EEF7');

  const html = card(`
        <p>Hi ${escapeHtml(firstName)},</p>
        <p style="margin:0 0 4px">Your week</p>
        <p style="${muted};margin-top:0">${escapeHtml(summary.label)}</p>
        <p style="font-size:26px;font-weight:bold;margin:16px 0 4px">${escapeHtml(jd(summary.total))}</p>
        <p style="${muted};margin:0">${escapeHtml(summary.receipts)} receipts · average ${escapeHtml(jd(summary.average))}</p>
        <p style="margin:8px 0 0">${escapeHtml(change)}</p>
        ${h3('Top categories')}
        ${rows(summary.topCategories.map((c) => [escapeHtml(c.category), escapeHtml(jd(c.total))]))}
        ${summary.topStore ? `${h3('Top store')}${rows([[escapeHtml(summary.topStore.storeName), escapeHtml(jd(summary.topStore.total))]])}` : ''}
        ${summary.budgets.length ? `${h3(`Budgets this month (${summary.month})`)}${rows(summary.budgets.map((b) => [
    escapeHtml(b.category),
    `<span style="color:${budgetColor(b)}">${escapeHtml(`${formatAmount(b.spent)} / ${formatAmount(b.limit)} JD (${b.percent}%)`)}</span>`]))}` : ''}
        <p style="${muted};margin-top:24px">${escapeHtml(WEEKLY_FOOTER)}</p>`);

  await sendMail({
    to,
    toName: firstName,
    subject: `Your Nexus week: ${summary.label}`,
    text: textLines.join('\n'),
    html,
  });
}

module.exports = {
  mailProvider, isMailConfigured, sendVerificationEmail, sendReceiptEmail, sendReportEmail,
  sendBudgetAlertEmail, sendWeeklySummaryEmail,
};
