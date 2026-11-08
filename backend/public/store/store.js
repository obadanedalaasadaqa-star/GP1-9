// Nexus Store Simulator: a cashier page that sends receipts to a customer's
// Nexus account. Plain JS, no build step. Server text is always shown with
// textContent (never innerHTML).
(function () {
  'use strict';

  const API = '/api/store';
  const KEY_STORAGE = 'nexus_store_key';
  // Same format the server accepts (routes/auth.js generateSerial()).
  const SERIAL_RE = /^NXS-[0-9A-F]{5}-[0-9A-F]{5}$/;
  const SCAN_EVERY_MS = 150;

  // Fixed catalog per store category. Prices in JD, at most 3 decimals (fils).
  const CATALOG = {
    Supermarket: [
      ['Milk 1L', 1.25], ['Bread', 0.5], ['Eggs x12', 2.1], ['Chicken 1kg', 3.75],
      ['Rice 2kg', 2.995], ['Olive Oil 1L', 6.5], ['Tomatoes 1kg', 0.85], ['Water 6-pack', 1.2],
    ],
    Food: [
      ['Falafel plate', 1.75], ['Hummus', 1.25], ['Shawarma', 2.5], ['Mansaf', 6.0],
      ['Fresh Juice', 1.5], ['Knafeh', 2.25], ['Tea', 0.5],
    ],
    Pharmacy: [
      ['Panadol x20', 1.95], ['Vitamin C', 4.5], ['Hand Sanitizer', 1.75], ['Face Masks x10', 2.0],
      ['Toothpaste', 2.35], ['Sunscreen', 9.9], ['Bandages', 1.15],
    ],
    Clothing: [
      ['T-Shirt', 9.99], ['Jeans', 24.5], ['Hoodie', 19.0], ['Socks x3', 4.5],
      ['Cap', 7.25], ['Scarf', 6.75],
    ],
    Electronics: [
      ['USB-C Cable', 4.99], ['Phone Case', 7.5], ['Screen Protector', 3.25], ['Power Bank', 18.0],
      ['Earbuds', 24.99], ['Charger 20W', 11.5],
    ],
  };

  const $ = (id) => document.getElementById(id);
  const els = {
    loginView: $('login-view'), posView: $('pos-view'),
    loginForm: $('login-form'), storeKey: $('store-key'), loginError: $('login-error'), loginBtn: $('login-btn'),
    badge: $('store-badge'), storeLabel: $('store-label'), signOut: $('sign-out'),
    products: $('products'), cart: $('cart'), cartEmpty: $('cart-empty'), total: $('total'), clearCart: $('clear-cart'),
    scanBtn: $('scan-btn'), scanner: $('scanner'), video: $('video'), stopScan: $('stop-scan'),
    scanError: $('scan-error'), frame: $('frame'),
    serial: $('serial'), emailCopy: $('email-copy'),
    sendBtn: $('send-btn'), sendError: $('send-error'),
    sent: $('sent'), sentDetail: $('sent-detail'), newSale: $('new-sale'),
  };

  let storeKey = null;
  let cart = []; // { name, unitPrice, qty }
  let sending = false;
  let stream = null;
  let scanTimer = null;

  // ── Money: fils integers, like the server ───────────────────────────────
  const toFils = (jd) => Math.round(jd * 1000);
  const cartFils = () => cart.reduce((sum, l) => sum + l.qty * toFils(l.unitPrice), 0);
  const jd = (fils) => `${(fils / 1000).toFixed(2)} JD`;

  // ── API ─────────────────────────────────────────────────────────────────
  async function api(path, options = {}) {
    const res = await fetch(API + path, {
      ...options,
      headers: { 'Content-Type': 'application/json', 'X-Store-Key': storeKey, ...(options.headers || {}) },
    });
    let body = {};
    try { body = await res.json(); } catch { /* non-JSON reply */ }
    if (!res.ok) throw new Error(body.error || `Request failed (${res.status}).`);
    return body;
  }

  // ── 1. Login ────────────────────────────────────────────────────────────
  async function signIn(key) {
    storeKey = key;
    els.loginError.textContent = '';
    els.loginBtn.disabled = true;
    try {
      const store = await api('/me');
      sessionStorage.setItem(KEY_STORAGE, key);
      showPos(store);
    } catch (err) {
      storeKey = null;
      sessionStorage.removeItem(KEY_STORAGE);
      els.loginError.textContent = err.message;
    } finally {
      els.loginBtn.disabled = false;
    }
  }

  function signOut() {
    stopCamera();
    storeKey = null;
    sessionStorage.removeItem(KEY_STORAGE);
    newSale();
    els.storeKey.value = '';
    els.badge.hidden = true;
    els.posView.hidden = true;
    els.loginView.hidden = false;
  }

  function showPos(store) {
    els.storeLabel.textContent = `${store.name} · ${store.category}`;
    els.badge.hidden = false;
    els.loginView.hidden = true;
    els.posView.hidden = false;
    renderProducts(CATALOG[store.category] || CATALOG.Supermarket);
    renderCart();
  }

  // ── 2. Products ─────────────────────────────────────────────────────────
  function renderProducts(products) {
    els.products.replaceChildren(...products.map(([name, price]) => {
      const btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'product';
      const n = document.createElement('span');
      n.className = 'name';
      n.textContent = name;
      const p = document.createElement('span');
      p.className = 'price';
      p.textContent = `${price.toFixed(3)} JD`;
      btn.append(n, p);
      btn.addEventListener('click', () => addToCart(name, price));
      return btn;
    }));
  }

  // ── 3. Cart ─────────────────────────────────────────────────────────────
  function addToCart(name, unitPrice) {
    const line = cart.find((l) => l.name === name);
    if (line) line.qty = Math.min(line.qty + 1, 999);
    else cart.push({ name, unitPrice, qty: 1 });
    hideSent();
    renderCart();
  }

  function changeQty(index, delta) {
    const line = cart[index];
    line.qty = Math.min(line.qty + delta, 999);
    if (line.qty < 1) cart.splice(index, 1);
    hideSent();
    renderCart();
  }

  function renderCart() {
    els.cart.replaceChildren(...cart.map((line, i) => {
      const li = document.createElement('li');

      const info = document.createElement('div');
      const name = document.createElement('div');
      name.className = 'line-name';
      name.textContent = line.name;
      const price = document.createElement('div');
      price.className = 'line-price';
      price.textContent = `${line.unitPrice.toFixed(3)} × ${line.qty} = ${jd(line.qty * toFils(line.unitPrice))}`;
      info.append(name, price);

      const qty = document.createElement('div');
      qty.className = 'qty';
      const minus = document.createElement('button');
      minus.type = 'button';
      minus.textContent = '−';
      minus.addEventListener('click', () => changeQty(i, -1));
      const count = document.createElement('span');
      count.textContent = String(line.qty);
      const plus = document.createElement('button');
      plus.type = 'button';
      plus.textContent = '+';
      plus.addEventListener('click', () => changeQty(i, 1));
      qty.append(minus, count, plus);

      const remove = document.createElement('button');
      remove.type = 'button';
      remove.className = 'remove';
      remove.title = 'Remove';
      remove.textContent = '×';
      remove.addEventListener('click', () => { cart.splice(i, 1); hideSent(); renderCart(); });

      li.append(info, qty, remove);
      return li;
    }));
    els.cartEmpty.hidden = cart.length > 0;
    els.total.textContent = jd(cartFils());
    updateSendButton();
  }

  // ── 4. Customer: QR scan or typed serial ────────────────────────────────
  function currentSerial() {
    return els.serial.value.trim().toUpperCase();
  }

  // "NEXUS:<serial>:<id>" (the app's QR) or a bare serial → serial, else null.
  function serialFromQr(text) {
    const raw = String(text || '').trim();
    const candidate = (raw.startsWith('NEXUS:') ? raw.split(':')[1] : raw).toUpperCase();
    return SERIAL_RE.test(candidate) ? candidate : null;
  }

  async function startCamera() {
    els.scanError.textContent = '';
    if (!navigator.mediaDevices?.getUserMedia) {
      els.scanError.textContent = 'This browser cannot use the camera here (needs HTTPS or localhost).';
      return;
    }
    try {
      stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: 'environment' } });
    } catch (err) {
      els.scanError.textContent = `Camera not available: ${err.message}`;
      return;
    }
    els.video.srcObject = stream;
    await els.video.play().catch(() => {});
    els.scanner.hidden = false;
    els.scanBtn.hidden = true;
    scanFrame();
  }

  function stopCamera() {
    clearTimeout(scanTimer);
    scanTimer = null;
    if (stream) stream.getTracks().forEach((t) => t.stop());
    stream = null;
    els.video.srcObject = null;
    els.scanner.hidden = true;
    els.scanBtn.hidden = false;
  }

  function scanFrame() {
    if (!stream) return;
    const { video, frame } = els;
    if (video.readyState >= video.HAVE_CURRENT_DATA && video.videoWidth > 0) {
      frame.width = video.videoWidth;
      frame.height = video.videoHeight;
      const ctx = frame.getContext('2d', { willReadFrequently: true });
      ctx.drawImage(video, 0, 0, frame.width, frame.height);
      const image = ctx.getImageData(0, 0, frame.width, frame.height);
      const code = window.jsQR(image.data, image.width, image.height, { inversionAttempts: 'dontInvert' });
      if (code) {
        const serial = serialFromQr(code.data);
        if (serial) {
          els.serial.value = serial;
          stopCamera();
          hideSent();
          updateSendButton();
          return;
        }
        els.scanError.textContent = 'That QR code is not a Nexus customer code.';
      }
    }
    scanTimer = setTimeout(scanFrame, SCAN_EVERY_MS);
  }

  // ── 6. Send ─────────────────────────────────────────────────────────────
  function updateSendButton() {
    els.sendBtn.disabled = sending || cart.length === 0 || !SERIAL_RE.test(currentSerial());
  }

  async function sendReceipt() {
    if (sending) return;
    sending = true;
    els.sendError.textContent = '';
    els.sendBtn.textContent = 'Sending...';
    updateSendButton();
    try {
      const result = await api('/receipts', {
        method: 'POST',
        body: JSON.stringify({
          customerSerial: currentSerial(),
          items: cart.map((l) => ({ name: l.name, qty: l.qty, unitPrice: l.unitPrice })),
          totalAmount: cartFils() / 1000,
          emailCopy: els.emailCopy.checked,
        }),
      });
      els.sentDetail.textContent = `to ${result.customerFirstName} · +${result.pointsEarned} pts`;
      els.sent.hidden = false;
      els.sendBtn.hidden = true;
    } catch (err) {
      // Keep the cart so the cashier can retry.
      els.sendError.textContent = err.message;
    } finally {
      sending = false;
      els.sendBtn.textContent = 'Send receipt';
      updateSendButton();
    }
  }

  function hideSent() {
    els.sent.hidden = true;
    els.sendBtn.hidden = false;
  }

  function newSale() {
    cart = [];
    els.serial.value = '';
    els.emailCopy.checked = false;
    els.sendError.textContent = '';
    els.scanError.textContent = '';
    hideSent();
    renderCart();
  }

  // ── Wiring ──────────────────────────────────────────────────────────────
  els.loginForm.addEventListener('submit', (e) => {
    e.preventDefault();
    const key = els.storeKey.value.trim();
    if (!key) { els.loginError.textContent = 'Enter the store key.'; return; }
    signIn(key);
  });
  els.signOut.addEventListener('click', signOut);
  els.clearCart.addEventListener('click', () => { cart = []; hideSent(); renderCart(); });
  els.scanBtn.addEventListener('click', startCamera);
  els.stopScan.addEventListener('click', stopCamera);
  els.serial.addEventListener('input', () => {
    const pos = els.serial.selectionStart;
    els.serial.value = els.serial.value.toUpperCase();
    els.serial.setSelectionRange(pos, pos);
    hideSent();
    updateSendButton();
  });
  els.sendBtn.addEventListener('click', sendReceipt);
  els.newSale.addEventListener('click', newSale);

  const saved = sessionStorage.getItem(KEY_STORAGE);
  if (saved) signIn(saved);
})();
