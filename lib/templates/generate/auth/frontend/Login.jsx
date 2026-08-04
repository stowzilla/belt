import { useState } from 'react'
import { signIn, completeNewPassword } from '../lib/auth'

export default function Login({ onLogin }) {
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [newPassword, setNewPassword] = useState('')
  const [error, setError] = useState('')
  const [challenge, setChallenge] = useState(null)
  const [loading, setLoading] = useState(false)

  async function handleSubmit(e) {
    e.preventDefault()
    setError('')
    setLoading(true)

    try {
      const result = await signIn(email, password)
      if (result.challenge === 'NEW_PASSWORD_REQUIRED') {
        setChallenge(result)
      } else {
        onLogin()
      }
    } catch (err) {
      setError(err.message || 'Sign in failed')
    } finally {
      setLoading(false)
    }
  }

  async function handleNewPassword(e) {
    e.preventDefault()
    setError('')
    setLoading(true)

    try {
      await completeNewPassword(email, newPassword, challenge.session)
      onLogin()
    } catch (err) {
      setError(err.message || 'Password change failed')
    } finally {
      setLoading(false)
    }
  }

  if (challenge) {
    return (
      <div className="auth-page">
        <form className="auth-form" onSubmit={handleNewPassword}>
          <h2>Set New Password</h2>
          <p>Please set a permanent password for your account.</p>
          {error && <div className="auth-error">{error}</div>}
          <input type="password" placeholder="New password" value={newPassword}
            onChange={e => setNewPassword(e.target.value)} required autoFocus />
          <button type="submit" disabled={loading}>
            {loading ? 'Saving...' : 'Set Password'}
          </button>
        </form>
      </div>
    )
  }

  return (
    <div className="auth-page">
      <form className="auth-form" onSubmit={handleSubmit}>
        <h2>Sign In</h2>
        {error && <div className="auth-error">{error}</div>}
        <input type="email" placeholder="Email" value={email}
          onChange={e => setEmail(e.target.value)} required autoFocus />
        <input type="password" placeholder="Password" value={password}
          onChange={e => setPassword(e.target.value)} required />
        <button type="submit" disabled={loading}>
          {loading ? 'Signing in...' : 'Sign In'}
        </button>
        <p className="auth-link">
          Don't have an account? <a href="/signup">Sign up</a>
        </p>
      </form>
    </div>
  )
}
