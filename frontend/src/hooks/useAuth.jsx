import { useState, useEffect, createContext, useContext } from 'react';
import api from '../lib/api';

const AuthContext = createContext(null);

export function AuthProvider({ children }) {
  const [user, setUser] = useState(() => {
    try {
      const saved = localStorage.getItem('nexus_user');
      return saved ? JSON.parse(saved) : null;
    } catch {
      localStorage.removeItem('nexus_user');
      localStorage.removeItem('nexus_token');
      return null;
    }
  });
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const token = localStorage.getItem('nexus_token');
    if (!token) { setLoading(false); return; }
    api.get('/user/me')
      .then((res) => { setUser(res.data); localStorage.setItem('nexus_user', JSON.stringify(res.data)); })
      .catch(() => { localStorage.removeItem('nexus_token'); localStorage.removeItem('nexus_user'); setUser(null); })
      .finally(() => setLoading(false));
  }, []);

  const login = (token, userData) => {
    localStorage.setItem('nexus_token', token);
    localStorage.setItem('nexus_user', JSON.stringify(userData));
    setUser(userData);
  };

  const logout = () => {
    localStorage.removeItem('nexus_token');
    localStorage.removeItem('nexus_user');
    setUser(null);
  };

  const refreshUser = () =>
    api.get('/user/me').then((res) => {
      setUser(res.data);
      localStorage.setItem('nexus_user', JSON.stringify(res.data));
      return res.data;
    });

  return (
    <AuthContext.Provider value={{ user, loading, login, logout, refreshUser, setUser }}>
      {children}
    </AuthContext.Provider>
  );
}

export const useAuth = () => useContext(AuthContext);
