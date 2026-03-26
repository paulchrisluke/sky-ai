// Admin auth shared module - compile-safe policy and helper layer
// No side effects, no route handlers, no signature verification yet

// Admin access claims interface
export interface AdminAccessClaims {
  email?: string;
  sub?: string;
  aud?: string | string[];
  iss?: string;
  exp?: number;
  iat?: number;
  [key: string]: unknown;
}

// Admin auth result interface
export interface AdminAuthResult {
  ok: boolean;
  status: number;
  email: string | null;
  reason: string | null;
  claims: AdminAccessClaims | null;
}

// Super admin email constant
export const SUPER_ADMIN_EMAIL = 'paulchrisluke@gmail.com';

// Extract bearer token from request
export function extractBearerToken(request: Request): string | null {
  const authHeader = request.headers.get('Authorization');
  if (!authHeader) return null;

  const parts = authHeader.trim().split(/\s+/);
  if (parts.length !== 2) return null;
  if (parts[0].toLowerCase() !== 'bearer') return null;
  if (!parts[1]) return null;

  return parts[1];
}

// Decode JWT payload without verification
export function decodeJwtPayload(token: string): AdminAccessClaims | null {
  try {
    const parts = token.split('.');
    if (parts.length !== 3) return null;

    const payloadSegment = parts[1];
    if (!payloadSegment) return null;

    let payload = payloadSegment.replace(/-/g, '+').replace(/_/g, '/');
    while (payload.length % 4 !== 0) payload += '=';

    if (typeof atob !== 'function') return null;

    const decoded = atob(payload);
    const parsed = JSON.parse(decoded);

    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
      return null;
    }

    return parsed as AdminAccessClaims;
  } catch {
    return null;
  }
}

// Check if email is allowed super admin
export function isAllowedSuperAdminEmail(email: string | null | undefined): boolean {
  if (!email) {
    return false;
  }
  return email.trim().toLowerCase() === SUPER_ADMIN_EMAIL.toLowerCase();
}

// Validate admin access from JWT token
export function validateAdminAccessFromJwt(token: string): AdminAuthResult {
  const claims = decodeJwtPayload(token);

  if (!claims) {
    return {
      ok: false,
      status: 401,
      email: null,
      reason: 'Malformed or invalid JWT token',
      claims: null,
    };
  }

  const email = typeof claims.email === 'string' ? claims.email : null;

  if (!email) {
    return {
      ok: false,
      status: 401,
      email: null,
      reason: 'JWT missing email claim',
      claims,
    };
  }

  if (!isAllowedSuperAdminEmail(email)) {
    return {
      ok: false,
      status: 403,
      email,
      reason: 'Email not authorized for admin access',
      claims,
    };
  }

  return {
    ok: true,
    status: 200,
    email,
    reason: null,
    claims,
  };
}

// Require admin access from request
export function requireAdminAccess(request: Request): AdminAuthResult {
  const token = extractBearerToken(request);

  if (!token) {
    return {
      ok: false,
      status: 401,
      email: null,
      reason: 'Missing or invalid Authorization header',
      claims: null,
    };
  }

  return validateAdminAccessFromJwt(token);
}
