import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useAuth } from '../hooks/useAuth.jsx';
import api from '../lib/api';

export default function AuthPage() {
  const [tab, setTab] = useState('login'); // 'login' | 'register'
  const [form, setForm] = useState({ name: '', email: '', password: '' });
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const { login } = useAuth();
  const navigate = useNavigate();

  const update = (k) => (e) => setForm((p) => ({ ...p, [k]: e.target.value }));

  const submit = async (e) => {
    e.preventDefault();
    setError('');
    setLoading(true);
    try {
      const endpoint = tab === 'login' ? '/auth/login' : '/auth/register';
      const payload = tab === 'login'
        ? { email: form.email, password: form.password }
        : { name: form.name, email: form.email, password: form.password };
      const { data } = await api.post(endpoint, payload);
      login(data.token, data.user);
      navigate('/dashboard');
    } catch (err) {
      setError(err.response?.data?.error ?? 'Something went wrong.');
    } finally {
      setLoading(false);
    }
  };

  const s = {
    page: {
      minHeight: '100vh', display: 'flex', alignItems: 'center', justifyContent: 'center',
      padding: '24px',
    },
    card: {
      width: '100%', maxWidth: 420,
      background: 'rgba(255,255,255,0.03)',
      border: '1px solid rgba(255,255,255,0.08)',
      borderRadius: 'var(--radius)',
      padding: '40px 36px',
      backdropFilter: 'blur(20px)',
      boxShadow: '0 24px 64px rgba(0,0,0,0.5)',
      animation: 'fadeUp 0.5s ease',
    },
    logo: {
      fontFamily: 'var(--font-head)',
      fontWeight: 800, fontSize: 28, textAlign: 'center',
      background: 'linear-gradient(135deg, #60a5fa, #a78bfa)',
      WebkitBackgroundClip: 'text', WebkitTextFillColor: 'transparent',
      marginBottom: 6,
    },
    tagline: {
      textAlign: 'center', fontSize: 13, color: 'var(--text-muted)',
      fontWeight: 400, marginBottom: 32,
    },
    tabs: {
      display: 'flex', background: 'rgba(255,255,255,0.04)',
      borderRadius: 'var(--radius-sm)', padding: 4, marginBottom: 28,
    },
    tab: (active) => ({
      flex: 1, padding: '9px 0', borderRadius: 8, fontSize: 14, fontWeight: 600,
      fontFamily: 'var(--font-body)',
      background: active ? 'rgba(59,130,246,0.2)' : 'transparent',
      color: active ? '#60a5fa' : 'var(--text-muted)',
      border: active ? '1px solid rgba(59,130,246,0.3)' : '1px solid transparent',
      cursor: 'pointer', transition: 'all 0.2s',
    }),
    label: { fontSize: 13, fontWeight: 500, color: 'var(--text-dim)', marginBottom: 8, display: 'block' },
    input: {
      width: '100%', padding: '12px 16px', borderRadius: 'var(--radius-sm)',
      background: 'rgba(255,255,255,0.05)',
      border: '1px solid rgba(255,255,255,0.1)',
      color: 'var(--text)', fontSize: 15, marginBottom: 16,
      transition: 'border-color 0.2s',
    },
    btn: {
      width: '100%', padding: '13px', marginTop: 4, borderRadius: 'var(--radius-sm)',
      background: 'linear-gradient(135deg, #3b82f6, #8b5cf6)',
      color: '#fff', fontWeight: 600, fontSize: 15, letterSpacing: '0.3px',
      transition: 'opacity 0.2s, transform 0.15s',
      opacity: loading ? 0.7 : 1,
      cursor: loading ? 'not-allowed' : 'pointer',
    },
    error: {
      background: 'rgba(239,68,68,0.1)', border: '1px solid rgba(239,68,68,0.3)',
      color: '#fca5a5', borderRadius: 'var(--radius-sm)', padding: '10px 14px',
      fontSize: 13, marginBottom: 16,
    },
  };

  return (
    <div style={s.page}>
      <div style={s.card}>
        <div style={s.logo}>NEXUS</div>
        <p style={s.tagline}>Smart Expense Tracking & Loyalty</p>

        <div style={s.tabs}>
          <button style={s.tab(tab === 'login')}    onClick={() => { setTab('login');    setError(''); }}>Sign In</button>
          <button style={s.tab(tab === 'register')} onClick={() => { setTab('register'); setError(''); }}>Register</button>
        </div>

        <form onSubmit={submit}>
          {tab === 'register' && (
            <div style={{ animation: 'fadeUp 0.3s ease' }}>
              <label style={s.label}>Full Name</label>
              <input
                style={s.input} type="text" placeholder="Your full name"
                value={form.name} onChange={update('name')} required
                onFocus={e => e.target.style.borderColor = 'rgba(59,130,246,0.5)'}
                onBlur={e  => e.target.style.borderColor = 'rgba(255,255,255,0.1)'}
              />
            </div>
          )}

          <label style={s.label}>Email</label>
          <input
            style={s.input} type="email" placeholder="you@example.com"
            value={form.email} onChange={update('email')} required
            onFocus={e => e.target.style.borderColor = 'rgba(59,130,246,0.5)'}
            onBlur={e  => e.target.style.borderColor = 'rgba(255,255,255,0.1)'}
          />

          <label style={s.label}>Password</label>
          <input
            style={s.input} type="password" placeholder="••••••••"
            value={form.password} onChange={update('password')} required minLength={6}
            onFocus={e => e.target.style.borderColor = 'rgba(59,130,246,0.5)'}
            onBlur={e  => e.target.style.borderColor = 'rgba(255,255,255,0.1)'}
          />

          {error && <div style={s.error}>{error}</div>}

          <button type="submit" style={s.btn} disabled={loading}>
            {loading ? 'Please wait…' : tab === 'login' ? 'Sign In' : 'Create Account'}
          </button>
        </form>
      </div>
    </div>
  );
}
