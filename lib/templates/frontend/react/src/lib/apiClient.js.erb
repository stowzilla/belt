const API_URL = import.meta.env.VITE_API_URL || 'http://localhost:3000'

export async function apiClient(path, options = {}) {
  const { method = 'GET', body, headers = {} } = options

  const config = {
    method,
    headers: { 'Content-Type': 'application/json', ...headers }
  }

  if (body) config.body = JSON.stringify(body)

  const response = await fetch(`${API_URL}${path}`, config)
  const data = await response.json()

  if (!response.ok) throw new Error(data.error || `Request failed: ${response.status}`)

  return data
}
