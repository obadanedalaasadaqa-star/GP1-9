import { useState } from 'react';
import { QRCodeSVG } from 'qrcode.react';
import { useAuth } from '../hooks/useAuth.jsx';

export default function Dashboard() {
  const { user } = useAuth();
  const [copied, setCopied] = useState(false);

  const qrValue = `NEXUS:${user.serialNumber}:${user.id}`;

  const copy = () => {
    navigator.clipboard.writeText(user.serialNumber);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  const s = {
    page: {
      minHeight: '100vh', paddingTop: 80, paddingBottom: 40,
      padding: '80px 24px 40px',
      maxWidth: 640, margin: '0 auto',
    },
    greeting: {
      fontFamily: 'var(--font-head)', fontWeight: 700,
      fontSize: 'clamp(22px, 5vw, 30px)', marginBottom: 4,
      animation: 'fadeUp 0.4s ease',
    },
    sub: { color: 'var(--text-muted)', fontSize: 14, marginBottom: 32, animation: 'fadeUp 0.4s 0.05s ease both' },

    qrCard: {
      background: 'rgba(255,255,255,0.03)',
      border: '1px solid rgba(255,255,255,0.08)',
      borderRadius: 'var(--radius)', padding: '32px 24px',
      display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 24,
      backdropFilter: 'blur(20px)',
      animation: 'fadeUp 0.4s 0.1s ease both',
      marginBottom: 16,
    },
    qrLabel: {
      fontFamily: 'var(--font-head)', fontWeight: 600, fontSize: 13,
      letterSpacing: '0.15em', textTransform: 'uppercase',
      color: 'var(--text-muted)',
    },
    qrFrame: {
      padding: 20, borderRadius: 20,
      background: '#fff',
      boxShadow: '0 0 0 1px rgba(255,255,255,0.1), 0 0 40px rgba(59,130,246,0.25)',
      animation: 'pulse-glow 3s ease-in-out infinite',
      position: 'relative', overflow: 'hidden',
    },
    scanLine: {
      position: 'absolute', left: 0, right: 0, height: 2,
      background: 'linear-gradient(90deg, transparent, rgba(59,130,246,0.8), transparent)',
      animation: 'scan-line 2.5s ease-in-out infinite',
    },
    qrHint: { fontSize: 13, color: 'var(--text-muted)', textAlign: 'center', lineHeight: 1.6 },

    serialCard: {
      background: 'rgba(255,255,255,0.03)',
      border: '1px solid rgba(255,255,255,0.08)',
      borderRadius: 'var(--radius)',
      padding: '20px 24px',
      display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12,
      backdropFilter: 'blur(20px)',
      animation: 'fadeUp 0.4s 0.15s ease both',
      marginBottom: 16,
    },
    serialLeft: {},
    serialTitle: { fontSize: 12, color: 'var(--text-muted)', fontWeight: 500, letterSpacing: '0.1em', textTransform: 'uppercase', marginBottom: 6 },
    serialNum: {
      fontFamily: 'var(--font-mono)', fontSize: 20, fontWeight: 500,
      letterSpacing: '0.08em',
      background: 'linear-gradient(135deg, #60a5fa, #a78bfa)',
      WebkitBackgroundClip: 'text', WebkitTextFillColor: 'transparent',
    },
    copyBtn: {
      padding: '8px 18px', borderRadius: 'var(--radius-pill)',
      background: copied ? 'rgba(16,185,129,0.15)' : 'rgba(59,130,246,0.12)',
      border: `1px solid ${copied ? 'rgba(16,185,129,0.35)' : 'rgba(59,130,246,0.25)'}`,
      color: copied ? '#6ee7b7' : '#60a5fa',
      fontSize: 13, fontWeight: 600, letterSpacing: '0.02em',
      transition: 'all 0.25s', cursor: 'pointer', whiteSpace: 'nowrap',
    },

    statsRow: {
      display: 'grid', gridTemplateColumns: '1fr 1fr',
      gap: 12, animation: 'fadeUp 0.4s 0.2s ease both',
    },
    statCard: {
      background: 'rgba(255,255,255,0.03)',
      border: '1px solid rgba(255,255,255,0.08)',
      borderRadius: 'var(--radius)', padding: '18px 20px',
      backdropFilter: 'blur(20px)',
    },
    statLabel: { fontSize: 11, color: 'var(--text-muted)', fontWeight: 500, letterSpacing: '0.1em', textTransform: 'uppercase', marginBottom: 8 },
    statValue: { fontFamily: 'var(--font-head)', fontWeight: 700, fontSize: 26 },
  };

  return (
    <div style={s.page}>
      <h1 style={s.greeting}>Welcome back, {user.name.split(' ')[0]} 👋</h1>
      <p style={s.sub}>Show your QR code at checkout — stores will scan it automatically.</p>

      {/* QR Card */}
      <div style={s.qrCard}>
        <span style={s.qrLabel}>Your Checkout QR</span>
        <div style={s.qrFrame}>
          <div style={s.scanLine} />
          <QRCodeSVG
            value={qrValue}
            size={220}
            bgColor="#ffffff"
            fgColor="#0f172a"
            level="H"
            includeMargin={false}
          />
        </div>
        <p style={s.qrHint}>
          Present this at any Nexus-enabled store.<br />
          No scanning or manual input required.
        </p>
      </div>

      {/* Serial Number */}
      <div style={s.serialCard}>
        <div style={s.serialLeft}>
          <div style={s.serialTitle}>Serial Number</div>
          <div style={s.serialNum}>{user.serialNumber}</div>
        </div>
        <button style={s.copyBtn} onClick={copy}>
          {copied ? '✓ Copied' : 'Copy'}
        </button>
      </div>

      {/* Stats */}
      <div style={s.statsRow}>
        <div style={s.statCard}>
          <div style={s.statLabel}>Loyalty Points</div>
          <div style={{ ...s.statValue, background: 'linear-gradient(135deg,#fbbf24,#f59e0b)', WebkitBackgroundClip: 'text', WebkitTextFillColor: 'transparent' }}>
            {user.loyaltyPoints}
          </div>
        </div>
        <div style={s.statCard}>
          <div style={s.statLabel}>Member Since</div>
          <div style={{ ...s.statValue, fontSize: 16, color: 'var(--text-dim)', fontFamily: 'var(--font-body)', paddingTop: 4 }}>
            {new Date(user.createdAt).toLocaleDateString('en-US', { month: 'short', year: 'numeric' })}
          </div>
        </div>
      </div>
    </div>
  );
}
