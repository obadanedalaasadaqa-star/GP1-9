import { NavLink, useNavigate } from 'react-router-dom';
import { useAuth } from '../hooks/useAuth.jsx';

const s = {
  nav: {
    position: 'fixed', top: 0, left: 0, right: 0, zIndex: 100,
    display: 'flex', alignItems: 'center', justifyContent: 'space-between',
    padding: '0 24px', height: 60,
    background: 'rgba(8,11,18,0.8)',
    backdropFilter: 'blur(20px)',
    borderBottom: '1px solid rgba(255,255,255,0.06)',
  },
  logo: {
    fontFamily: 'var(--font-head)',
    fontWeight: 800, fontSize: 20,
    background: 'linear-gradient(135deg, #60a5fa, #a78bfa)',
    WebkitBackgroundClip: 'text', WebkitTextFillColor: 'transparent',
    letterSpacing: '-0.5px',
  },
  links: { display: 'flex', gap: 4, alignItems: 'center' },
  link: (active) => ({
    fontFamily: 'var(--font-body)',
    fontWeight: 500, fontSize: 14,
    padding: '6px 14px', borderRadius: 'var(--radius-pill)',
    color: active ? '#f1f5f9' : 'var(--text-muted)',
    background: active ? 'rgba(255,255,255,0.08)' : 'transparent',
    transition: 'all 0.2s',
  }),
  logout: {
    fontFamily: 'var(--font-body)',
    fontWeight: 500, fontSize: 14,
    padding: '6px 14px', borderRadius: 'var(--radius-pill)',
    color: 'var(--text-muted)',
    background: 'transparent',
    transition: 'all 0.2s',
    cursor: 'pointer', border: 'none',
  },
};

export default function Nav() {
  const { logout } = useAuth();
  const navigate = useNavigate();

  const handleLogout = () => { logout(); navigate('/'); };

  return (
    <nav style={s.nav}>
      <span style={s.logo}>NEXUS</span>
      <div style={s.links}>
        <NavLink to="/dashboard" style={({ isActive }) => s.link(isActive)}>Dashboard</NavLink>
        <NavLink to="/profile"   style={({ isActive }) => s.link(isActive)}>Profile</NavLink>
        <button style={s.logout} onClick={handleLogout}
          onMouseEnter={e => e.target.style.color = '#ef4444'}
          onMouseLeave={e => e.target.style.color = 'var(--text-muted)'}>
          Sign out
        </button>
      </div>
    </nav>
  );
}
