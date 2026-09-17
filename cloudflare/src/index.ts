import { Container, getContainer } from '@cloudflare/containers'
import { env as workerEnv } from 'cloudflare:workers'

const REQUIRED_RAILS_ENV = [
  'DATABASE_URL',
  'OPERATOR_DATABASE_URL',
  'SECRET_KEY_BASE',
  'GOOGLE_CLIENT_ID',
  'GOOGLE_CLIENT_SECRET',
  'ADMIN_EMAIL_ALLOWLIST',
  'OPERATOR_EMAIL_ALLOWLIST',
  'PUBLIC_BASE_URL',
  'ADMIN_FRONTEND_URL',
  'OPERATOR_FRONTEND_URL',
  'GOOGLE_OAUTH_CALLBACK_URL',
  'OPERATOR_GOOGLE_OAUTH_CALLBACK_URL',
  'R2_ENDPOINT',
  'R2_BUCKET',
  'R2_ACCESS_KEY_ID',
  'R2_SECRET_ACCESS_KEY',
] as const

const bindings = workerEnv as unknown as Record<string, string | undefined>

function railsEnvironment(): Record<string, string> {
  return Object.fromEntries([
    ['ACTIVE_STORAGE_SERVICE', 'r2'],
    ['PORT', '8080'],
    ['RAILS_ENV', 'production'],
    ['RAILS_MAX_THREADS', '5'],
    ['R2_REGION', bindings.R2_REGION ?? 'auto'],
    ...REQUIRED_RAILS_ENV.map((name) => [name, bindings[name] ?? '']),
  ])
}

function missingRailsEnvironment() {
  return REQUIRED_RAILS_ENV.filter((name) => !bindings[name]?.trim())
}

export class RailsContainer extends Container<Env> {
  defaultPort = 8080
  sleepAfter = '10m'
  pingEndpoint = '/health'
  envVars = railsEnvironment()
}

export default {
  async fetch(request: Request, env: Env) {
    const missing = missingRailsEnvironment()
    if (missing.length > 0) {
      return Response.json(
        {
          error: 'backend_not_configured',
          message: 'Required Rails Worker secrets are not configured.',
          missing,
        },
        { status: 503 },
      )
    }

    return getContainer(env.RAILS_CONTAINER, 'production').fetch(request)
  },
}
