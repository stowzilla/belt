import { getToken } from './auth'

const API_URL = import.meta.env.VITE_API_URL || 'http://localhost:3000'

export async function apiClient(path, options = {}) {
  const { method = 'GET', body, headers = {} } = options

  const token = getToken()
  const config = {
    method,
    headers: {
      Accept: 'application/json',
      ...(token ? { Authorization: token } : {}),
      ...headers
    }
  }

  if (body !== undefined && body !== null) {
    config.headers['Content-Type'] = 'application/json'
    config.body = JSON.stringify(body)
  }

  const response = await fetch(`${API_URL}${path}`, config)
  const data = await response.json()

  if (response.status === 401) {
    window.location.href = '/login'
    throw new Error('Unauthorized')
  }

  if (!response.ok) throw new Error(data.error || `Request failed: ${response.status}`)

  return data
}
