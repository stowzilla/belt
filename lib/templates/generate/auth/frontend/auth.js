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
      newPasswordRequired: (_userAttributes, requiredAttributes) => {
        // Stash the user + the attributes Cognito actually requires so
        // completeNewPassword can continue the SRP session and supply exactly
        // what the pool asks for — no more, no less.
        pendingUser = cognitoUser
        pendingRequiredAttributes = requiredAttributes || []
        resolve({ challenge: 'NEW_PASSWORD_REQUIRED' })
      }
    })
  })
}

// Holds the CognitoUser mid-challenge for the NEW_PASSWORD_REQUIRED flow,
// plus the list of attributes Cognito flagged as required for the challenge.
let pendingUser = null
let pendingRequiredAttributes = []

export function completeNewPassword(email, newPassword) {
  if (!pendingUser) {
    return Promise.reject(new Error('No pending password challenge. Sign in again.'))
  }

  // Only supply attributes Cognito actually asks for in this challenge.
  //   - If the pool requires `email` and the user doesn't have it yet, it shows
  //     up in requiredAttributes → we send it (username is the email). Skipping
  //     it would fail with "Invalid attributes given, email is missing".
  //   - If the user already has `email` (e.g. admin-created with it), it is NOT
  //     in requiredAttributes → we must NOT send it, or Cognito rejects with
  //     "Cannot modify an already provided email".
  const attributes = {}
  if (pendingRequiredAttributes.includes('email')) {
    attributes.email = email
  }

  return new Promise((resolve, reject) => {
    pendingUser.completeNewPasswordChallenge(newPassword, attributes, {
      onSuccess: (session) => {
        setTokens({
          IdToken: session.getIdToken().getJwtToken(),
          RefreshToken: session.getRefreshToken().getToken()
        })
        pendingUser = null
        pendingRequiredAttributes = []
        resolve({ success: true })
      },
      onFailure: (err) => {
        pendingUser = null
        pendingRequiredAttributes = []
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
