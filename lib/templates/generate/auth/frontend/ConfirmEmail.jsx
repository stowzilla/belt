import { useState } from 'react'
import { confirmSignUp } from '../lib/auth'

export default function ConfirmEmail() {
  const params = new URLSearchParams(window.location.search)
  const [email, setEmail] = useState(params.get('email') || '')
  const [code, setCode] = useState('')
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(false)
  const [confirmed, setConfirmed] = useState(false)

  async function handleSubmit(e) {
    e.preventDefault()
    setError('')
    setLoading(true)

    try {
      await confirmSignUp(email, code)
      setConfirmed(true)
    } catch (err) {
      setError(err.message || 'Confirmation failed')
    } finally {
      setLoading(false)
    }
  }

  if (confirmed) {
    return (
      <div className="auth-page">
        <div className="auth-form">
          <h2>Email Verified! ✓</h2>
          <p>Your account is ready.</p>
          <a href="/login" className="auth-btn">Sign In</a>
        </div>
      </div>
    )
  }

  return (
    <div className="auth-page">
      <form className="auth-form" onSubmit={handleSubmit}>
        <h2>Verify Email</h2>
        <p>Enter the code sent to your email.</p>
        {error && <div className="auth-error">{error}</div>}
        <input type="email" placeholder="Email" value={email}
          onChange={e => setEmail(e.target.value)} required />
        <input type="text" placeholder="Verification code" value={code}
          onChange={e => setCode(e.target.value)} required autoFocus />
        <button type="submit" disabled={loading}>
          {loading ? 'Verifying...' : 'Verify'}
        </button>
      </form>
    </div>
  )
}
