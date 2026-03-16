export function chunkText(text: string, size: number, overlap: number, maxChunks: number): string[] {
  const normalized = cleanEmailBody(text).replace(/\s+/g, ' ').trim();
  if (!normalized) return [];

  const chunks: string[] = [];
  let start = 0;
  while (start < normalized.length) {
    const end = Math.min(normalized.length, start + size);
    const candidate = cleanChunkCandidate(normalized.slice(start, end));
    if (candidate && !isNoiseHeavyChunk(candidate)) {
      chunks.push(candidate);
    }
    if (chunks.length >= maxChunks) break;
    if (end >= normalized.length) break;
    start = Math.max(0, end - overlap);
  }

  return chunks;
}

export function cleanEmailBody(raw: string): string {
  const headerNames =
    '(Return-Path|Received|MIME-Version|Content-Type|Content-Transfer-Encoding|X-[\\w-]+|Message-ID|Date|From|To|Cc|Bcc|Subject|Reply-To|Delivered-To|Authentication-Results|DKIM-Signature|ARC-[\\w-]+)';

  let cleaned = raw
    .replace(
      /^(Return-Path|Received|MIME-Version|Content-Type|Content-Transfer-Encoding|X-[\w-]+|Message-ID|Date|From|To|Cc|Bcc|Subject|Reply-To|Delivered-To|Authentication-Results|DKIM-Signature|ARC-[\w-]+):.*$/gim,
      ''
    )
    .replace(/^>\s?/gm, '')
    .replace(/^-{3,}.*Forwarded.*-{3,}$/gim, '')
    .replace(/^(unsubscribe|this email was sent|you are receiving|view in browser|privacy policy).*/gim, '')
    .replace(/^(sent from my|get outlook for|this email and any attachments).*/gim, '')
    .replace(/^(begin:vcalendar|end:vcalendar|begin:vevent|dtstart|dtend|organizer).*/gim, '')
    .replace(/^(confidentiality notice|this message is intended only for).*/gim, '')
    .replace(/\n{3,}/g, '\n\n')
    .replace(/(?:^|\s)-{2,}=?_part_[^\s]+/gi, ' ')
    .replace(/(?:^|\s)boundary\s*=\s*"[^"]*"/gi, ' ')
    .replace(/(?:^|\s)boundary\s*=\s*[^"\s]+/gi, ' ')
    .replace(/(?:^|\s)multipart\/[a-z0-9-]+/gi, ' ')
    .trim();

  cleaned = cleaned.replace(
    new RegExp(`(?:^|\\s)${headerNames}:\\s*[^\\n]*?(?=(?:\\s${headerNames}:)|$)`, 'gi'),
    ' '
  );

  return cleaned
    .replace(/[A-Za-z0-9+/]{100,}={0,2}/g, '')
    .replace(/=([0-9A-Fa-f]{2})/g, (_, hex: string) => String.fromCharCode(Number.parseInt(hex, 16)))
    .replace(/=\n/g, '')
    .replace(/https?:\/\/[^\s)>"']+/gi, (url: string) => sanitizeTrackedUrl(url))
    .replace(/<[^>]{1,300}>/g, ' ')
    .replace(/@font-face\s*\{[^}]*\}/gi, ' ')
    .replace(/\s+/g, ' ')
    .replace(/(visit help center|contact airbnb|airbnb,\s*inc\.|unsubscribe|privacy policy)[\s\S]*$/i, '')
    .replace(/\s{2,}/g, ' ')
    .trim();
}

export function cleanChunkCandidate(raw: string): string {
  return raw
    .replace(/https?:\/\/a0\.muscache\.com\/[^\s)>"']+/gi, ' ')
    .replace(/https?:\/\/(?:www\.)?(facebook|instagram|twitter)\.com\/[^\s)>"']+/gi, ' ')
    .replace(/\b(?:visit help center|contact airbnb)\b/gi, ' ')
    .replace(/@font-face\b[^.]{0,500}/gi, ' ')
    .replace(/\s{2,}/g, ' ')
    .trim();
}

export function isNoiseHeavyChunk(text: string): boolean {
  const lower = text.toLowerCase();
  const actionableHits = (lower.match(/\b(please|could you|can you|request|deadline|due|status|next step|additional information|invoice|contract|meeting|approved|denied|appeal|listing|support|question)\b|\?/g) || []).length;
  const noiseHits = (lower.match(/(@font-face|<html|<head|<style|<\/?(div|table|tr|td|span)\b|mso-|viewport|airbnb,\s*inc\.|visit help center|contact airbnb|facebook\.com|instagram\.com|twitter\.com|a0\.muscache\.com|content="text\/html")/g) || []).length;
  const linkCount = (text.match(/https?:\/\//g) || []).length;
  const symbolCount = (text.match(/[<>{};=_]/g) || []).length;
  const symbolRatio = text.length > 0 ? symbolCount / text.length : 0;

  if (noiseHits >= 2 && actionableHits === 0) return true;
  if (linkCount >= 5 && actionableHits === 0) return true;
  if (symbolRatio > 0.2 && actionableHits === 0) return true;
  return false;
}

export function htmlToText(input: string): string {
  const cleaned = input
    .replace(/<!--[\s\S]*?-->/g, ' ')
    .replace(/<head[\s\S]*?<\/head>/gi, ' ')
    .replace(/<(script|style|noscript|svg|canvas|form|footer|nav|header)[\s\S]*?<\/\1>/gi, ' ')
    .replace(/<[^>]*style=["'][^"']*display\s*:\s*none[^"']*["'][^>]*>[\s\S]*?<\/[^>]+>/gi, ' ')
    .replace(/<a[^>]*href=["']([^"']+)["'][^>]*>([\s\S]*?)<\/a>/gi, (_m, href: string, text: string) => {
      const label = text.replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ').trim();
      const sanitized = sanitizeTrackedUrl(href);
      return label ? `${label} ${sanitized}` : sanitized;
    })
    .replace(/<br\s*\/?>/gi, '\n')
    .replace(/<\/(p|div|section|article|li|tr|h[1-6])>/gi, '\n')
    .replace(/<[^>]*>/g, ' ');

  return decodeHtmlEntities(cleaned)
    .replace(/https?:\/\/[^\s)>"']+/gi, (url: string) => sanitizeTrackedUrl(url))
    .replace(/\s+\n/g, '\n')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}

function sanitizeTrackedUrl(rawUrl: string): string {
  try {
    const u = new URL(rawUrl);
    if (u.hostname.endsWith('airbnb.com') && u.pathname === '/external_link') {
      const target = u.searchParams.get('url');
      if (target) {
        return sanitizeTrackedUrl(target);
      }
    }
    const kept = u.searchParams
      .keys()
      .filter((k) => !/^utm_/i.test(k) && !/^(gclid|fbclid|mc_eid|mc_cid|euid|trk|tracking|campaign|c)$/i.test(k));
    const clean = new URL(`${u.protocol}//${u.host}${u.pathname}`);
    for (const key of kept) {
      const values = u.searchParams.getAll(key);
      for (const value of values) clean.searchParams.append(key, value);
    }
    return clean.toString();
  } catch {
    return rawUrl.replace(/\?.*$/, '');
  }
}

function decodeHtmlEntities(input: string): string {
  return input
    .replace(/&nbsp;/gi, ' ')
    .replace(/&amp;/gi, '&')
    .replace(/&lt;/gi, '<')
    .replace(/&gt;/gi, '>')
    .replace(/&quot;/gi, '"')
    .replace(/&#39;/gi, "'")
    .replace(/&#(\d+);/g, (_, dec: string) => String.fromCharCode(Number.parseInt(dec, 10)))
    .replace(/&#x([0-9a-fA-F]+);/g, (_, hex: string) => String.fromCharCode(Number.parseInt(hex, 16)));
}
