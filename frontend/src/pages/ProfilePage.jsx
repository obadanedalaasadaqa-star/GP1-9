import { useState } from 'react';
import { useAuth } from '../hooks/useAuth.jsx';
import api from '../lib/api';

export default function ProfilePage() {
  const { user, refreshUser } = useAuth();
  const [name, setName] = useState(user.name);
  const [loading, setLoading] = useState(false);
  const [status, setStatus] = useState(null); // 'success' | 'error'
  const [msg, setMsg] = useState('');

  const save = async (e) => {
    e.preventDefault();
    if (name.trim() === user.name) return;
    setLoading(true); setStatus(null);
    try {
      await api.patch('/user/me', { name: name.trim() });
      await refreshUser();
      setStatus('success'); setMsg('Profile updated.');
    } catch (err) {
      setStatus('error'); setMsg(err.response?.data?.error ?? 'Update failed.');
    } finally {
      setLoading(false);
    }
  };

  const s = {
    page: { minHeight: '100vh', padding: '80px 24px 40px', maxWidth: 540, margin: '0 auto' },
    title: { fontFamily: 'var(--font-head)', fontWeight: 700, fontSize: 26, marginBottom: 4, animation: 'fadeUp 0.4s ease' },
    sub: { color: 'var(--text-muted)', fontSize: 14, marginBottom: 32, animation: 'fadeUp 0.4s 0.05s ease both' },
    card: {
      background: 'rgba(255,255,255,0.03)', border: '1px solid rgba(255,255,255,0.08)',
      borderRadius: 'var(--radius)', padding: '28px 24px', backdropFilter: 'blur(20px)',
      animation: 'fadeUp 0.4s 0.1s ease both', marginBottom: 16,
    },
    sectionTitle: { fontSize: 12, color: 'var(--text-muted)', fontWeight: 500, letterSpacing: '0.1em', textTransform: 'uppercase', marginBottom: 16 },
    row: { display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '12px 0', borderBottom: '1px solid rgba(255,255,255,0.05)' },
    rowLabel: { fontSize: 13, color: 'var(--text-muted)' },
    rowValue: { fontSize: 14, fontWeight: 500 },
    mono: { fontFamily: 'var(--font-mono)', fontSize: 13, color: '#a78bfa' },
    label: { fontSize: 13, fontWeight: 500, color: 'var(--text-dim)', marginBottom: 8, display: 'block' },
    input: {
      width: '100%', padding: '12px 16px', borderRadius: 'var(--radius-sm)',
      background: 'rgba(255,255,255,0.05)', border: '1px solid rgba(255,255,255,0.1)',
      color: 'var(--text)', fontSize: 15, marginBottom: 16, transition: 'border-color 0.2s',
    },
    btn: {
      padding: '11px 24px', borderRadius: 'var(--radius-sm)',
      background: 'linear-gradient(135deg, #3b82f6, #8b5cf6)',
      color: '#fff', fontWeight: 600, fontSize: 14, opacity: loading ? 0.6 : 1,
      cursor: loading ? 'not-allowed' : 'pointer', transition: 'opacity 0.2s',
    },
    alert: (type) => ({
      padding: '10px 14px', borderRadius: 'var(--radius-sm)', fontSize: 13, marginBottom: 12,
      background: type === 'success' ? 'rgba(16,185,129,0.1)' : 'rgba(239,68,68,0.1)',
      border: `1px solid ${type === 'success' ? 'rgba(16,185,129,0.3)' : 'rgba(239,68,68,0.3)'}`,
      color: type === 'success' ? '#6ee7b7' : '#fca5a5',
    }),
  };

  return (
    <div style={s.page}>
      <h1 style={s.title}>Profile</h1>
      <p style={s.sub}>Manage your Nexus account details.</p>

      {/* Account info */}
      <div style={s.card}>
        <div style={s.sectionTitle}>Account Info</div>
        <div style={s.row}>
          <span style={s.rowLabel}>Email</span>
          <span style={s.rowValue}>{user.email}</span>
        </div>
        <div style={s.row}>
          <span style={s.rowLabel}>Serial Number</span>
          <span style={s.mono}>{user.serialNumber}</span>
        </div>
        <div style={{ ...s.row, borderBottom: 'none' }}>
          <span style={s.rowLabel}>Loyalty Points</span>
          <span style={{ ...s.rowValue, color: '#fbbf24' }}>{user.loyaltyPoints} pts</span>
        </div>
      </div>

      {/* Edit */}
      <div style={{ ...s.card, animation: 'fadeUp 0.4s 0.15s ease both' }}>
        <div style={s.sectionTitle}>Edit Profile</div>
        <form onSubmit={save}>
          <label style={s.label}>Display Name</label>
          <input
            style={s.input} type="text" value={name}
            onChange={(e) => setName(e.target.value)} required
            onFocus={e => e.target.style.borderColor = 'rgba(59,130,246,0.5)'}
            onBlur={e  => e.target.style.borderColor = 'rgba(255,255,255,0.1)'}
          />
          {status && <div style={s.alert(status)}>{msg}</div>}
          <button type="submit" style={s.btn} disabled={loading}>
            {loading ? 'Saving…' : 'Save Changes'}
          </button>
        </form>
      </div>
    </div>
  );
}
