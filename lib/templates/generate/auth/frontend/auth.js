import {
  CognitoIdentityProviderClient,
  InitiateAuthCommand,
  RespondToAuthChallengeCommand,
  SignUpCommand,
  ConfirmSignUpCommand
} from '@aws-sdk/client-cognito-identity-provider'

const REGION = import.meta.env.VITE_AWS_REGION
const CLIENT_ID = import.meta.env.VITE_COGNITO_CLIENT_ID

const client = new CognitoIdentityProviderClient({ region: REGION })

let idToken = null
let refreshToken = null

export function getToken() { return idToken }
export function isAuthenticated() { return idToken !== null }

export async function signIn(username, password) {
  const response = await client.send(new InitiateAuthCommand({
    AuthFlow: 'USER_PASSWORD_AUTH',
    ClientId: CLIENT_ID,
    AuthParameters: { USERNAME: username, PASSWORD: password }
  }))

  if (response.ChallengeName === 'NEW_PASSWORD_REQUIRED') {
    return { challenge: 'NEW_PASSWORD_REQUIRED', session: response.Session }
  }

  setTokens(response.AuthenticationResult)
  return { success: true }
}

export async function signUp(email, password) {
  await client.send(new SignUpCommand({
    ClientId: CLIENT_ID,
    Username: email,
    Password: password
  }))
  return { needsConfirmation: true }
}

export async function confirmSignUp(email, code) {
  await client.send(new ConfirmSignUpCommand({
    ClientId: CLIENT_ID,
    Username: email,
    ConfirmationCode: code
  }))
  return { success: true }
}

export async function completeNewPassword(username, newPassword, session) {
  const response = await client.send(new RespondToAuthChallengeCommand({
    ChallengeName: 'NEW_PASSWORD_REQUIRED',
    ClientId: CLIENT_ID,
    Session: session,
    ChallengeResponses: {
      USERNAME: username,
      NEW_PASSWORD: newPassword,
      'userAttributes.email': username
    }
  }))
  setTokens(response.AuthenticationResult)
  return { success: true }
}

export function signOut() {
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
