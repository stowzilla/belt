import React from 'react'
import ReactDOM from 'react-dom/client'
import { BrowserRouter } from 'react-router-dom'
import App from './App'
import './index.css'

const root = document.getElementById('root')
const app = (
  <React.StrictMode>
    <BrowserRouter>
      <App />
    </BrowserRouter>
  </React.StrictMode>
)

// Pages prerendered at build time hydrate. Anything else (including the SPA
// fallback serving index.html for a deep link) renders fresh.
const normalize = (path) => path.replace(/\/+$/, '') || '/'
if (root.dataset.prerendered && normalize(root.dataset.prerendered) === normalize(window.location.pathname)) {
  ReactDOM.hydrateRoot(root, app)
} else {
  ReactDOM.createRoot(root).render(app)
}
