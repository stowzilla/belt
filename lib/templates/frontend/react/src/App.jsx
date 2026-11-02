import { Routes, Route } from 'react-router-dom'
import Home from './pages/Home'

// The router lives in main.jsx (browser) and entry-server.jsx (prerender).
function App() {
  return (
    <Routes>
      <Route path="/" element={<Home />} />
    </Routes>
  )
}

export default App
