import {
  CognitoUserPool,
  CognitoUser,
  AuthenticationDetails,
  CognitoUserAttribute
} from 'amazon-cognito-identity-js'

const REGION = import.meta.env.VITE_AWS_REGION
const CLIENT_ID = import.meta.env.VITE_COGNITO_CLIENT_ID
const USER_POOL_ID = import.meta.env.VITE_COGNITO_USER_POOL_ID

// amazon-cognito-identity-js uses SRP (Secure Remote Password) by default.
// The password is NEVER sent over the wire — only the SRP_A proof is
// transmitted, so credentials can't leak into request logs or proxies.
const userPool = new CognitoUserPool({
  UserPoolId: USER_POOL_ID,
  ClientId: CLIENT_ID
})

let idToken = null
let refreshToken = null

export function getToken() { return idToken }
export function isAuthenticated() { return idToken !== null }

export function signIn(username, password) {
  const cognitoUser = new CognitoUser({ Username: username, Pool: userPool })
  const authDetails = new AuthenticationDetails({ Username: username, Password: password })

  return new Promise((resolve, reject) => {
    cognitoUser.authenticateUser(authDetails, {
      onSuccess: (session) => {
        setTokens({
          IdToken: session.getIdToken().getJwtToken(),
          RefreshToken: session.getRefreshToken().getToken()
        })
        resolve({ success: true })
      },
      onFailure: (err) => reject(err),
      newPasswordRequired: () => {
        // Stash the user so completeNewPassword can continue the SRP session.
        pendingUser = cognitoUser
        resolve({ challenge: 'NEW_PASSWORD_REQUIRED' })
      }
    })
  })
}

// Holds the CognitoUser mid-challenge for the NEW_PASSWORD_REQUIRED flow.
let pendingUser = null

export function completeNewPassword(_username, newPassword) {
  if (!pendingUser) {
    return Promise.reject(new Error('No pending password challenge. Sign in again.'))
  }

  return new Promise((resolve, reject) => {
    pendingUser.completeNewPasswordChallenge(newPassword, {}, {
      onSuccess: (session) => {
        setTokens({
          IdToken: session.getIdToken().getJwtToken(),
          RefreshToken: session.getRefreshToken().getToken()
        })
        pendingUser = null
        resolve({ success: true })
      },
      onFailure: (err) => {
        pendingUser = null
        reject(err)
      }
    })
  })
}

export function signUp(email, password) {
  const attributes = [new CognitoUserAttribute({ Name: 'email', Value: email })]

  return new Promise((resolve, reject) => {
    userPool.signUp(email, password, attributes, null, (err) => {
      if (err) return reject(err)
      resolve({ needsConfirmation: true })
    })
  })
}

export function confirmSignUp(email, code) {
  const cognitoUser = new CognitoUser({ Username: email, Pool: userPool })

  return new Promise((resolve, reject) => {
    cognitoUser.confirmRegistration(code, true, (err) => {
      if (err) return reject(err)
      resolve({ success: true })
    })
  })
}

export function signOut() {
  const cognitoUser = userPool.getCurrentUser()
  if (cognitoUser) cognitoUser.signOut()
  idToken = null
  refreshToken = null
  localStorage.removeItem('idToken')
  localStorage.removeItem('refreshToken')
}

function setTokens(authResult) {
  idToken = authResult.IdToken
  refreshToken = authResult.RefreshToken
  localStorage.setItem('idToken', idToken)
  if (refreshToken) localStorage.setItem('refreshToken', refreshToken)
}

// Restore on page load
const stored = localStorage.getItem('idToken')
if (stored) idToken = stored
