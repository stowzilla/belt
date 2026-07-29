# Belt Security Review — July 2026

## Overview

Security audit of the Belt gem (v0.0.7) — a Ruby framework for serverless AWS Lambda applications.

**Review date:** 2026-07-29
**Reviewer:** Kaylee (automated security review)
**Scope:** All source files, dependencies, CI configuration, authentication patterns

## Findings Summary

| Severity | Count | Status |
|----------|-------|--------|
| Critical | 0 | — |
| High | 0 | — |
| Medium | 2 | 1 fixed, 1 documented |
| Low | 3 | Documented |
| Info | 6 | Positive observations |

## Fixed Issues

### 1. Path Traversal in Controller Resolution (Medium) ✅ FIXED

**File:** `lib/belt/action_router.rb` — `resolve_from_paths`

**Issue:** The method constructed file paths from controller names without validating for `..` sequences or ensuring resolved paths stayed within allowed directories. Although controller names come from static route manifests (not user input), this violates defense-in-depth principles.

**Fix applied:**
- Reject controller names containing `..`
- Resolve paths with `File.expand_path` and verify they remain within the allowed controller directory
- Use resolved absolute paths for `require` calls

## Documented Issues (No Fix Required)

### 2. Verbose Error Responses in Dev Environments (Medium)

**File:** `lib/belt/helpers/response.rb` (lines 41–50)

**Issue:** When `ENVIRONMENT` starts with `dev` or equals `local`/`test`, exception class names, messages, filtered backtraces, and environment identifiers are included in HTTP responses.

**Risk:** If a dev environment is accidentally exposed publicly, internal details could leak.

**Mitigation:** Acceptable pattern for development. Dev environments should never be publicly accessible without auth. API Gateway authorization provides the boundary.

### 3. CORS localhost in Non-Production (Low)

**File:** `lib/belt/helpers/cors_origin.rb`

**Issue:** Non-production/non-staging environments automatically include `http://localhost:3000` and `http://localhost:3001` in allowed origins.

**Mitigation:** CORS is browser-enforced and these environments require Cognito auth. Risk is minimal.

### 4. No Framework-Level Rate Limiting (Low)

**Issue:** Belt has no built-in rate limiting. Relies on API Gateway throttling/WAF externally.

**Mitigation:** Rate limiting is configured at the API Gateway and WAF layers, which is the standard AWS pattern.

### 5. No CSRF Protection (Low)

**Issue:** No CSRF token mechanism exists.

**Mitigation:** All authentication uses Bearer tokens (Cognito JWT via Authorization header), which is inherently CSRF-resistant. Cookie-based auth must never be added without CSRF protection.

## Positive Security Observations

1. **Gem signing** — RSA certificate signing with key stored as GitHub Actions secret, passphrase-protected, intermediate deleted after use
2. **CI security pipeline** — `bundler-audit` runs on every push/PR; tests across Ruby 3.2–3.4
3. **Strong parameters** — Requires explicit `permit()`, normalizes to snake_case, validates scalar types
4. **Authentication** — Delegates to Cognito JWT validated by API Gateway before reaching Lambda
5. **Exception hierarchy** — Known exceptions map to appropriate HTTP codes without leaking internals
6. **CORS allowlist** — Uses explicit origin list, never wildcard `*`

## Dependencies

All clean — `bundler-audit` reports **no vulnerabilities**.

| Dependency | Version | Status |
|-----------|---------|--------|
| lambda_loadout | ~> 0.0 | Clean |
| s3arch | ~> 0.0.5 | Clean (dev only) |

## Recommendations

1. **Add comprehensive specs** for ActionRouter, BeltController::Base, and Parameters (especially auth paths and error handling)
2. **Consider explicit CORS opt-in** for UAT environments rather than permissive non-prod defaults
3. **Document security expectations** — dev environments must not be publicly exposed without auth
