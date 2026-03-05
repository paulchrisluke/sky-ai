export type AccessAuthEnv = {
  ACCESS_AUD?: string;
  ACCESS_ISSUER?: string;
  ACCESS_JWKS_URL?: string;
};

export type AccessPrincipal = {
  type: 'access' | 'service';
  subject: string;
  email: string | null;
};

type JwksCacheEntry = {
  expiresAt: number;
  keysByKid: Record<string, JsonWebKey>;
};

const AUTH_CACHE = new Map<string, JwksCacheEntry>();

export function extractBearerToken(request: Request): string | null {
  const auth = request.headers.get('authorization') || '';
  const match = auth.match(/^Bearer\s+(.+)$/i);
  return match ? match[1].trim() : null;
}

export function principalFromAccessClaims(claims: Record<string, unknown>): AccessPrincipal {
  const sub = typeof claims.sub === 'string' ? claims.sub : '';
  if (sub) {
    return {
      type: 'access',
      subject: sub,
      email: typeof claims.email === 'string' ? claims.email : null
    };
  }

  const commonName = typeof claims.common_name === 'string' ? claims.common_name : '';
  if (commonName) {
    return {
      type: 'service',
      subject: `service:${commonName}`,
      email: null
    };
  }

  throw new Error('jwt_missing_sub_or_common_name');
}

export async function verifyAccessJwtClaims(token: string, env: AccessAuthEnv): Promise<Record<string, unknown>> {
  const [encodedHeader, encodedPayload, encodedSig] = token.split('.');
  if (!encodedHeader || !encodedPayload || !encodedSig) {
    throw new Error('malformed_jwt');
  }

  const header = JSON.parse(decodeBase64Url(encodedHeader)) as { kid?: string; alg?: string };
  if (header.alg !== 'RS256' || !header.kid) {
    throw new Error('unsupported_jwt_alg_or_missing_kid');
  }

  const jwks = await getJwks(env);
  const jwk = jwks[header.kid];
  if (!jwk) throw new Error('jwks_kid_not_found');

  const key = await crypto.subtle.importKey(
    'jwk',
    jwk,
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['verify']
  );

  const signed = new TextEncoder().encode(`${encodedHeader}.${encodedPayload}`);
  const signature = decodeBase64UrlToBytes(encodedSig);
  const valid = await crypto.subtle.verify('RSASSA-PKCS1-v1_5', key, signature, signed);
  if (!valid) throw new Error('jwt_signature_invalid');

  const claims = JSON.parse(decodeBase64Url(encodedPayload)) as Record<string, unknown>;
  const now = Math.floor(Date.now() / 1000);
  if (typeof claims.exp !== 'number' || claims.exp <= now) throw new Error('jwt_expired');
  if (typeof claims.nbf === 'number' && claims.nbf > now) throw new Error('jwt_not_yet_valid');

  if (env.ACCESS_ISSUER && typeof claims.iss === 'string') {
    const iss = claims.iss.replace(/\/+$/, '');
    const expected = env.ACCESS_ISSUER.replace(/\/+$/, '');
    if (iss !== expected) throw new Error('jwt_issuer_mismatch');
  }

  if (env.ACCESS_AUD) {
    const aud = claims.aud;
    const ok = typeof aud === 'string' ? aud === env.ACCESS_AUD : Array.isArray(aud) && aud.includes(env.ACCESS_AUD);
    if (!ok) throw new Error('jwt_audience_mismatch');
  }

  return claims;
}

async function getJwks(env: AccessAuthEnv): Promise<Record<string, JsonWebKey>> {
  const jwksUrl = env.ACCESS_JWKS_URL || (env.ACCESS_ISSUER ? `${env.ACCESS_ISSUER.replace(/\/+$/, '')}/cdn-cgi/access/certs` : null);
  if (!jwksUrl) throw new Error('missing_access_jwks_url_or_issuer');

  const now = Date.now();
  const cached = AUTH_CACHE.get(jwksUrl);
  if (cached && cached.expiresAt > now) {
    return cached.keysByKid;
  }

  const res = await fetch(jwksUrl, { method: 'GET' });
  if (!res.ok) throw new Error(`jwks_fetch_failed_${res.status}`);
  const body = (await res.json()) as { keys?: JsonWebKey[] };
  const keys: Record<string, JsonWebKey> = {};
  for (const key of body.keys || []) {
    if (key.kid) keys[key.kid] = key;
  }

  AUTH_CACHE.set(jwksUrl, {
    keysByKid: keys,
    expiresAt: now + 10 * 60 * 1000
  });
  return keys;
}

function decodeBase64Url(input: string): string {
  const bytes = decodeBase64UrlToBytes(input);
  return new TextDecoder().decode(bytes);
}

function decodeBase64UrlToBytes(input: string): Uint8Array {
  const normalized = input.replace(/-/g, '+').replace(/_/g, '/');
  const padded = normalized + '='.repeat((4 - (normalized.length % 4)) % 4);
  const bin = atob(padded);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i += 1) out[i] = bin.charCodeAt(i);
  return out;
}
