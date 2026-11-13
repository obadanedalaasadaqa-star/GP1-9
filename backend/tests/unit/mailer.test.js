// The real mailer with fetch (Brevo) and nodemailer (Gmail) mocked.
// The env is set per test and the module is loaded fresh each time.
jest.mock('nodemailer');

const MAIL_VARS = ['BREVO_API_KEY', 'MAIL_FROM', 'MAIL_FROM_NAME', 'GMAIL_USER', 'GMAIL_APP_PASSWORD'];
const saved = {};
let gmailSend;
let realFetch;

function loadMailer(env) {
  for (const name of MAIL_VARS) delete process.env[name];
  Object.assign(process.env, env);
  jest.resetModules();
  const nodemailer = require('nodemailer');
  gmailSend = jest.fn(async () => ({}));
  nodemailer.createTransport.mockReturnValue({ sendMail: gmailSend });
  return require('../../src/lib/mailer');
}

const BREVO = { BREVO_API_KEY: 'test-brevo-key', MAIL_FROM: 'sender@example.com' };
const GMAIL = { GMAIL_USER: 'me@gmail.com', GMAIL_APP_PASSWORD: 'abcd efgh ijkl mnop' };

const okReply = () => ({ ok: true, status: 201, statusText: 'Created', json: async () => ({ messageId: 'x' }) });
const lastBrevoBody = () => JSON.parse(global.fetch.mock.calls.at(-1)[1].body);

beforeAll(() => {
  for (const name of MAIL_VARS) saved[name] = process.env[name];
  realFetch = global.fetch;
});
afterAll(() => {
  for (const name of MAIL_VARS) {
    if (saved[name] === undefined) delete process.env[name];
    else process.env[name] = saved[name];
  }
  global.fetch = realFetch;
});
beforeEach(() => {
  global.fetch = jest.fn(async () => okReply());
  jest.spyOn(console, 'log').mockImplementation(() => {});
});
afterEach(() => jest.restoreAllMocks());

describe('provider choice', () => {
  test('Brevo wins when both Brevo variables are set, even with Gmail set', async () => {
    const mailer = loadMailer({ ...BREVO, ...GMAIL });
    expect(mailer.mailProvider()).toBe('brevo');
    await mailer.sendVerificationEmail('a@example.com', 'Sara', '123456');
    expect(global.fetch).toHaveBeenCalledTimes(1);
    expect(gmailSend).not.toHaveBeenCalled();
  });

  test('Gmail when only Gmail is set', async () => {
    const mailer = loadMailer(GMAIL);
    expect(mailer.mailProvider()).toBe('gmail');
    await mailer.sendVerificationEmail('a@example.com', 'Sara', '123456');
    expect(gmailSend).toHaveBeenCalledTimes(1);
    expect(global.fetch).not.toHaveBeenCalled();
  });

  test('dev mode when nothing is set: logs [mail:dev] and sends nothing', async () => {
    const mailer = loadMailer({});
    expect(mailer.mailProvider()).toBeNull();
    expect(mailer.isMailConfigured()).toBe(false);
    await mailer.sendVerificationEmail('a@example.com', 'Sara', '123456');
    await mailer.sendReceiptEmail('a@example.com', 'Sara', {
      storeName: 'Carrefour', items: ['Milk x2'], totalAmount: 2.5, pointsEarned: 2, createdAt: new Date(),
    });
    expect(console.log).toHaveBeenCalledWith('[mail:dev] Verification code for a@example.com: 123456');
    expect(console.log).toHaveBeenCalledWith(expect.stringMatching(/^\[mail:dev\] Receipt copy for a@example.com: Carrefour/));
    expect(global.fetch).not.toHaveBeenCalled();
    expect(gmailSend).not.toHaveBeenCalled();
  });
});

describe('Brevo request', () => {
  test('sends the URL, api-key header and JSON body', async () => {
    const mailer = loadMailer({ ...BREVO, MAIL_FROM_NAME: 'Nexus' });
    await mailer.sendVerificationEmail('a@example.com', 'Sara', '123456');

    const [url, options] = global.fetch.mock.calls[0];
    expect(url).toBe('https://api.brevo.com/v3/smtp/email');
    expect(options.method).toBe('POST');
    expect(options.headers['api-key']).toBe('test-brevo-key');
    expect(options.headers['content-type']).toBe('application/json');
    const body = JSON.parse(options.body);
    expect(body.sender).toEqual({ name: 'Nexus', email: 'sender@example.com' });
    expect(body.to).toEqual([{ email: 'a@example.com', name: 'Sara' }]);
    expect(body.subject).toBe('123456 is your Nexus verification code');
    expect(body.textContent).toContain('Your Nexus verification code is: 123456');
    expect(body.htmlContent).toContain('123456');
  });

  test.each([null, ''])('leaves out to[0].name when the first name is %p', async (firstName) => {
    const mailer = loadMailer(BREVO);
    await mailer.sendVerificationEmail('a@example.com', firstName, '123456');
    expect(lastBrevoBody().to[0]).toEqual({ email: 'a@example.com' });
    expect(lastBrevoBody().to[0]).not.toHaveProperty('name');
  });

  test('a non-2xx reply rejects with the status', async () => {
    const mailer = loadMailer(BREVO);
    global.fetch.mockResolvedValueOnce({
      ok: false, status: 401, statusText: 'Unauthorized', json: async () => ({ message: 'Key not found' }),
    });
    await expect(mailer.sendVerificationEmail('a@example.com', 'Sara', '123456'))
      .rejects.toThrow('Brevo 401: Key not found');
  });
});

describe('escaping', () => {
  test('the receipt email escapes <script> in the store and item names', async () => {
    const mailer = loadMailer(BREVO);
    await mailer.sendReceiptEmail('a@example.com', 'Sara', {
      storeName: '<script>alert(1)</script>Mart',
      items: ['<script>x</script> x2', 'Bread'],
      totalAmount: 3,
      pointsEarned: 3,
      createdAt: new Date(),
    });
    const { htmlContent, subject } = lastBrevoBody();
    expect(htmlContent).not.toContain('<script>');
    expect(htmlContent).toContain('&lt;script&gt;alert(1)&lt;/script&gt;Mart');
    expect(htmlContent).toContain('&lt;script&gt;x&lt;/script&gt; x2');
    expect(htmlContent).toContain('3.00 JD');
    expect(htmlContent).toContain('+3 pts');
    expect(subject).toBe('Your receipt from <script>alert(1)</script>Mart: 3.00 JD');
  });

  test('the verification email escapes the first name in the HTML part', async () => {
    const mailer = loadMailer(BREVO);
    await mailer.sendVerificationEmail('a@example.com', '<a href="x">win</a>', '123456');
    const { htmlContent, textContent } = lastBrevoBody();
    expect(htmlContent).toContain('&lt;a href=&quot;x&quot;&gt;');
    expect(htmlContent).not.toContain('<a href="x">');
    // The plain-text part is unchanged.
    expect(textContent).toContain('Hi <a href="x">win</a>,');
  });
});

describe('sendReportEmail', () => {
  const report = (ai = {
    status: 'ready', headline: 'You spent 287.99 JD.', narrative: 'Mostly <b>Electronics</b>.', tips: ['Plan ahead.'],
  }) => ({
    range: { period: '1m', from: '2026-11-01', to: '2026-11-11', label: '1 – 11 Nov 2026', days: 11 },
    previous: { from: '2026-10-01', to: '2026-10-11', label: '1 – 11 Oct 2026' },
    totals: { total: 287.99, receipts: 7, average: 41.141 },
    comparison: { previousTotal: 0, previousReceipts: 0, difference: 287.99, changePercent: null, isNew: true },
    byCategory: [{ category: 'Electronics', total: 89.99, receipts: 1, sharePercent: 31, previousTotal: 0 }],
    byMonth: [{ month: '2026-11', label: 'November 2026', total: 287.99, receipts: 7, partial: true }],
    topStores: [{ storeName: '<script>alert(1)</script>', total: 89.99, receipts: 1 }],
    biggestReceipts: [{ date: '2026-11-03T09:12:00.000Z', storeName: 'iStore', category: 'Electronics', total: 89.99 }],
    ai,
  });

  test('Brevo: one fetch, subject, amounts, everything escaped, text part', async () => {
    const mailer = loadMailer(BREVO);
    await mailer.sendReportEmail('a@example.com', 'Sara', report());
    expect(global.fetch).toHaveBeenCalledTimes(1);
    const { subject, htmlContent, textContent } = lastBrevoBody();
    expect(subject).toBe('Your Nexus spending report: 1 – 11 Nov 2026');
    expect(htmlContent).toContain('287.99 JD');
    expect(htmlContent).toContain('41.14 JD');
    expect(htmlContent).not.toContain('<script>');
    expect(htmlContent).toContain('&lt;script&gt;alert(1)&lt;/script&gt;');
    expect(htmlContent).toContain('Mostly &lt;b&gt;Electronics&lt;/b&gt;.');
    expect(htmlContent).not.toContain('<b>Electronics</b>');
    expect(htmlContent).toContain('The summary is written by AI.');
    expect(textContent).toContain('Mostly <b>Electronics</b>.');
    expect(textContent).toContain('Compared with 1 – 11 Oct 2026: 0.00 JD (+287.99 JD, New)');
  });

  test('biggest receipts use the local date (Asia/Amman, 00:30 on 5 Nov)', async () => {
    const mailer = loadMailer(BREVO);
    const r = report();
    r.biggestReceipts = [{ date: '2026-11-04T21:30:00.000Z', storeName: 'iStore', category: 'Electronics', total: 89.99 }];
    await mailer.sendReportEmail('a@example.com', 'Sara', r, 180);
    const { htmlContent, textContent } = lastBrevoBody();
    expect(htmlContent).toContain('2026-11-05 · iStore');
    expect(htmlContent).not.toContain('2026-11-04');
    expect(textContent).toContain('- 2026-11-05 iStore (Electronics): 89.99 JD');
  });

  test('AI unavailable: the email says so', async () => {
    const mailer = loadMailer(BREVO);
    await mailer.sendReportEmail('a@example.com', 'Sara', report({ status: 'unavailable', error: 'x' }));
    const { htmlContent, textContent } = lastBrevoBody();
    expect(htmlContent).toContain('The AI summary is not available for this report.');
    expect(textContent).toContain('The AI summary is not available for this report.');
  });

  test('dev mode: no fetch, one [mail:dev] Report line', async () => {
    const mailer = loadMailer({});
    await mailer.sendReportEmail('a@example.com', 'Sara', report());
    expect(global.fetch).not.toHaveBeenCalled();
    expect(console.log).toHaveBeenCalledTimes(1);
    expect(console.log).toHaveBeenCalledWith('[mail:dev] Report for a@example.com: 1 – 11 Nov 2026, 287.99 JD, AI ready');
  });
});

describe('sendBudgetAlertEmail', () => {
  const alert = (over = {}) => ({
    receiptId: 'r1', category: 'Food', level: 80, percent: 85, spent: 8.5, limit: 10,
    remaining: 1.5, overBy: 0, month: '2026-11', monthLabel: 'November 2026', ...over,
  });

  test('80%: subject, amounts and what is left', async () => {
    const mailer = loadMailer(BREVO);
    await mailer.sendBudgetAlertEmail('a@example.com', 'Sara', alert());
    const { subject, htmlContent, textContent } = lastBrevoBody();
    expect(subject).toBe("You've used 85% of your Food budget");
    expect(htmlContent).toContain('8.50 JD of 10.00 JD used (85%)');
    expect(htmlContent).toContain('1.50 JD left');
    expect(textContent).toContain('Food budget, November 2026:');
    expect(textContent).toContain('Profile → Budgets & alerts');
  });

  test('100%: subject with the month and "Over by"', async () => {
    const mailer = loadMailer(BREVO);
    await mailer.sendBudgetAlertEmail('a@example.com', 'Sara',
      alert({ level: 100, percent: 105, spent: 10.5, remaining: 0, overBy: 0.5 }));
    const { subject, htmlContent } = lastBrevoBody();
    expect(subject).toBe("You're over your Food budget for November 2026");
    expect(htmlContent).toContain('Over by 0.50 JD');
  });

  test('a <script> category is escaped in the HTML', async () => {
    const mailer = loadMailer(BREVO);
    await mailer.sendBudgetAlertEmail('a@example.com', '<b>Sara</b>', alert({ category: '<script>x</script>' }));
    const { htmlContent } = lastBrevoBody();
    expect(htmlContent).not.toContain('<script>');
    expect(htmlContent).toContain('&lt;script&gt;x&lt;/script&gt;');
    expect(htmlContent).not.toContain('<b>Sara</b>');
  });

  test('dev mode: no fetch, one [mail:dev] Budget alert line', async () => {
    const mailer = loadMailer({});
    await mailer.sendBudgetAlertEmail('a@example.com', 'Sara', alert());
    expect(global.fetch).not.toHaveBeenCalled();
    expect(console.log).toHaveBeenCalledWith('[mail:dev] Budget alert for a@example.com: Food 80% (8.50 / 10.00 JD)');
  });
});

describe('sendWeeklySummaryEmail', () => {
  const summary = () => ({
    label: '8 – 14 Nov 2026', from: '2026-11-08', to: '2026-11-14',
    total: 75, receipts: 6, average: 12.5, previousTotal: 50, difference: 25, changePercent: 50,
    topCategories: [{ category: '<script>x</script>', total: 40, count: 3 }],
    topStore: { storeName: 'KFC & Co', total: 30, count: 2 },
    budgets: [{ category: 'Food', limit: 50, spent: 42.5, percent: 85, level: 'warning' }],
    month: 'November 2026',
  });

  test('subject, totals, change, budgets; dynamic values escaped', async () => {
    const mailer = loadMailer(BREVO);
    await mailer.sendWeeklySummaryEmail('a@example.com', 'Sara', summary());
    const { subject, htmlContent, textContent } = lastBrevoBody();
    expect(subject).toBe('Your Nexus week: 8 – 14 Nov 2026');
    expect(htmlContent).toContain('75.00 JD');
    expect(htmlContent).toContain('+25.00 JD (+50%) vs the week before (50.00 JD)');
    expect(htmlContent).not.toContain('<script>');
    expect(htmlContent).toContain('&lt;script&gt;x&lt;/script&gt;');
    expect(htmlContent).toContain('KFC &amp; Co');
    expect(htmlContent).toContain('42.50 / 50.00 JD (85%)');
    expect(textContent).toContain('- Food 42.50 / 50.00 JD (85%)');
    expect(textContent).toContain('Weekly summary is on in Nexus → Profile.');
  });

  test('no week before: the change shows "—"', async () => {
    const mailer = loadMailer(BREVO);
    await mailer.sendWeeklySummaryEmail('a@example.com', 'Sara',
      { ...summary(), previousTotal: 0, difference: 75, changePercent: null, budgets: [], topStore: null });
    const { textContent } = lastBrevoBody();
    expect(textContent).toContain('+75.00 JD (—)');
    expect(textContent).not.toContain('Budgets this month');
  });

  test('dev mode: no fetch, one [mail:dev] Weekly summary line', async () => {
    const mailer = loadMailer({});
    await mailer.sendWeeklySummaryEmail('a@example.com', 'Sara', summary());
    expect(global.fetch).not.toHaveBeenCalled();
    expect(console.log).toHaveBeenCalledWith('[mail:dev] Weekly summary for a@example.com: 8 – 14 Nov 2026, 75.00 JD');
  });
});
