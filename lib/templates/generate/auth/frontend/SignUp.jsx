import { useState } from 'react'
import { signUp } from '../../lib/auth'

export default function SignUp() {
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(false)
  const [needsConfirmation, setNeedsConfirmation] = useState(false)

  async function handleSubmit(e) {
    e.preventDefault()
    setError('')
    setLoading(true)

    try {
      const result = await signUp(email, password)
      if (result.needsConfirmation) setNeedsConfirmation(true)
    } catch (err) {
      setError(err.message || 'Sign up failed')
    } finally {
      setLoading(false)
    }
  }

  if (needsConfirmation) {
    return (
      <div className="auth-page">
        <div className="auth-form">
          <h2>Check Your Email</h2>
          <p>We sent a verification code to <strong>{email}</strong>.</p>
          <a href={`/confirm?email=${encodeURIComponent(email)}`} className="auth-btn">
            Enter Code
          </a>
        </div>
      </div>
    )
  }

  return (
    <div className="auth-page">
      <form className="auth-form" onSubmit={handleSubmit}>
        <h2>Create Account</h2>
        {error && <div className="auth-error">{error}</div>}
        <input type="email" placeholder="Email" value={email}
          onChange={e => setEmail(e.target.value)} required autoFocus />
        <input type="password" placeholder="Password (8+ characters)" value={password}
          onChange={e => setPassword(e.target.value)} required minLength={8} />
        <button type="submit" disabled={loading}>
          {loading ? 'Creating...' : 'Create Account'}
        </button>
        <p className="auth-link">
          Already have an account? <a href="/login">Sign in</a>
        </p>
      </form>
    </div>
  )
}
