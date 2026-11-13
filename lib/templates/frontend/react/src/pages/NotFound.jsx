import { Link } from 'react-router-dom'

// Shown for any address the app has no route for. `belt deploy frontend`
// prerenders it to 404.html, which CloudFront serves with HTTP 404, so crawlers
// and agents can tell a missing page from a real one.
function NotFound() {
  return (
    <main style={{ maxWidth: '36rem', margin: '4rem auto', padding: '0 1.5rem', fontFamily: 'system-ui, sans-serif' }}>
      <h1>Page not found</h1>
      <p>There is no page at this address.</p>
      <p>
        <Link to="/">Back to the home page</Link>
      </p>
    </main>
  )
}

export default NotFound
