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
