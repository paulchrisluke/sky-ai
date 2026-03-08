import https from 'node:https';
import http from 'node:http';

/**
 * Minimal CalDAV + iCal parser for Apple Calendar sync.
 * Polls all calendars and emits normalized event payloads.
 */

const CALDAV_HOST = process.env.CALDAV_HOST || 'caldav.icloud.com';
const LOOKAHEAD_DAYS = Number(process.env.CALENDAR_LOOKAHEAD_DAYS || '14');

function isoFromDate(date) {
  return date.toISOString();
}

function addDays(date, days) {
  const d = new Date(date);
  d.setUTCDate(d.getUTCDate() + days);
  return d;
}

function formatCalDAVDate(date) {
  return date.toISOString().replace(/[-:]/g, '').split('.')[0] + 'Z';
}

function basicAuth(user, pass) {
  return 'Basic ' + Buffer.from(`${user}:${pass}`).toString('base64');
}

async function caldavRequest({ method, path, body, headers, host }) {
  return new Promise((resolve, reject) => {
    const options = {
      hostname: host || CALDAV_HOST,
      port: 443,
      path,
      method,
      headers: {
        'Content-Type': 'application/xml; charset=utf-8',
        'Depth': '1',
        ...headers,
        ...(body ? { 'Content-Length': Buffer.byteLength(body) } : {})
      }
    };

    const req = https.request(options, (res) => {
      let data = '';
      res.on('data', (chunk) => { data += chunk; });
      res.on('end', () => resolve({ status: res.statusCode, body: data, headers: res.headers }));
    });

    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}

async function discoverPrincipal(email, password) {
  const body = `<?xml version="1.0" encoding="UTF-8"?>
<d:propfind xmlns:d="DAV:">
  <d:prop>
    <d:current-user-principal/>
  </d:prop>
</d:propfind>`;

  const res = await caldavRequest({
    method: 'PROPFIND',
    path: '/.well-known/caldav',
    body,
    headers: {
      'Authorization': basicAuth(email, password),
      'Depth': '0'
    }
  });

  const match = res.body.match(/<d:href[^>]*>([^<]+)<\/d:href>/i)
    || res.body.match(/<href[^>]*>([^<]+)<\/href>/i);
  if (!match) throw new Error(`caldav_principal_not_found status=${res.status}`);
  return match[1].trim();
}

async function discoverCalendarHome(email, password, principalPath) {
  const body = `<?xml version="1.0" encoding="UTF-8"?>
<d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:prop>
    <c:calendar-home-set/>
  </d:prop>
</d:propfind>`;

  const res = await caldavRequest({
    method: 'PROPFIND',
    path: principalPath,
    body,
    headers: {
      'Authorization': basicAuth(email, password),
      'Depth': '0'
    }
  });

  const match = res.body.match(/<[^>]*href[^>]*>([^<]*calendars[^<]*)<\/[^>]*href>/i)
    || res.body.match(/<href>([^<]+)<\/href>/gi);

  if (!match) throw new Error('caldav_calendar_home_not_found');
  const raw = typeof match === 'string' ? match : match[0];
  return raw.replace(/<\/?[^>]+>/g, '').trim();
}

async function listCalendars(email, password, calendarHomePath) {
  const body = `<?xml version="1.0" encoding="UTF-8"?>
<d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:cs="http://calendarserver.org/ns/">
  <d:prop>
    <d:displayname/>
    <d:resourcetype/>
    <cs:getctag/>
  </d:prop>
</d:propfind>`;

  const res = await caldavRequest({
    method: 'PROPFIND',
    path: calendarHomePath,
    body,
    headers: {
      'Authorization': basicAuth(email, password),
      'Depth': '1'
    }
  });

  const calendars = [];
  const responseBlocks = res.body.split(/<\/?d:response>/i).filter((b) => b.includes('calendar'));

  for (const block of responseBlocks) {
    const hrefMatch = block.match(/<d:href[^>]*>([^<]+)<\/d:href>/i);
    const nameMatch = block.match(/<d:displayname[^>]*>([^<]*)<\/d:displayname>/i);
    const isCalendar = /<d:calendar\s*\/>/.test(block) || /calendar/.test(block);

    if (!hrefMatch || !isCalendar) continue;
    const href = hrefMatch[1].trim();
    if (href === calendarHomePath || href === calendarHomePath + '/') continue;

    calendars.push({
      id: href,
      name: nameMatch ? nameMatch[1].trim() : href.split('/').filter(Boolean).pop()
    });
  }

  return calendars;
}

async function fetchCalendarEvents(email, password, calendarPath, rangeStart, rangeEnd) {
  const body = `<?xml version="1.0" encoding="UTF-8"?>
<c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:prop>
    <d:getetag/>
    <c:calendar-data/>
  </d:prop>
  <c:filter>
    <c:comp-filter name="VCALENDAR">
      <c:comp-filter name="VEVENT">
        <c:time-range start="${formatCalDAVDate(rangeStart)}" end="${formatCalDAVDate(rangeEnd)}"/>
      </c:comp-filter>
    </c:comp-filter>
  </c:filter>
</c:calendar-query>`;

  const res = await caldavRequest({
    method: 'REPORT',
    path: calendarPath,
    body,
    headers: {
      'Authorization': basicAuth(email, password),
      'Depth': '1'
    }
  });

  return extractIcalBlocks(res.body);
}

function extractIcalBlocks(xmlBody) {
  const blocks = [];
  const regex = /BEGIN:VCALENDAR[\s\S]*?END:VCALENDAR/gi;
  let match;
  while ((match = regex.exec(xmlBody)) !== null) {
    blocks.push(match[0]);
  }
  return blocks;
}

function parseIcalEvent(icalText) {
  const eventMatch = icalText.match(/BEGIN:VEVENT([\s\S]*?)END:VEVENT/i);
  if (!eventMatch) return null;

  const block = eventMatch[1];

  function getField(name) {
    const re = new RegExp(`^${name}[^:\r\n]*:([^\r\n]*)`, 'im');
    const m = block.match(re);
    if (!m) return null;
    return unfoldIcal(m[1].trim());
  }

  function unfoldIcal(str) {
    return str.replace(/\r?\n[ \t]/g, '');
  }

  const uid = getField('UID');
  const summary = getField('SUMMARY');
  const description = getField('DESCRIPTION');
  const location = getField('LOCATION');
  const status = (getField('STATUS') || 'CONFIRMED').toUpperCase();
  const rrule = getField('RRULE');

  const dtstart = getField('DTSTART') || getField('DTSTART;VALUE=DATE') || getField('DTSTART;TZID=[^:]+');
  const dtend = getField('DTEND') || getField('DTEND;VALUE=DATE') || getField('DTEND;TZID=[^:]+');

  const organizerRaw = getField('ORGANIZER');
  const organizerEmail = organizerRaw ? (organizerRaw.replace(/^mailto:/i, '').trim()) : null;
  const organizerNameMatch = block.match(/ORGANIZER[^:\r\n]*CN=([^;:\r\n]+)/i);
  const organizerName = organizerNameMatch ? organizerNameMatch[1].trim() : null;

  const attendees = [];
  const attendeeRegex = /ATTENDEE[^:\r\n]*:([^\r\n]+)/gi;
  let aMatch;
  while ((aMatch = attendeeRegex.exec(block)) !== null) {
    const email = aMatch[1].replace(/^mailto:/i, '').trim();
    const nameMatch = aMatch[0].match(/CN=([^;:\r\n]+)/i);
    attendees.push({ email, name: nameMatch ? nameMatch[1].trim() : null });
  }

  if (!uid || !dtstart) return null;

  const allDay = /^\d{8}$/.test(dtstart.replace(/[TZ]/g, ''));
  const startAt = parseIcalDate(dtstart);
  const endAt = parseIcalDate(dtend || dtstart);

  if (!startAt || !endAt) return null;

  return {
    uid,
    title: summary ? decodeIcalText(summary) : null,
    description: description ? decodeIcalText(description) : null,
    location: location ? decodeIcalText(location) : null,
    startAt,
    endAt,
    allDay,
    recurrenceRule: rrule || null,
    status: mapIcalStatus(status),
    organizerEmail,
    organizerName,
    attendees,
    rawIcal: icalText.slice(0, 4000)
  };
}

function parseIcalDate(raw) {
  if (!raw) return null;
  const clean = raw.replace(/^[^:]+:/, '').trim();
  if (/^\d{8}$/.test(clean)) {
    const y = clean.slice(0, 4), m = clean.slice(4, 6), d = clean.slice(6, 8);
    return `${y}-${m}-${d}T00:00:00.000Z`;
  }
  if (/^\d{8}T\d{6}Z?$/.test(clean)) {
    const y = clean.slice(0, 4), mo = clean.slice(4, 6), d = clean.slice(6, 8);
    const h = clean.slice(9, 11), mi = clean.slice(11, 13), s = clean.slice(13, 15);
    return `${y}-${mo}-${d}T${h}:${mi}:${s}.000Z`;
  }
  try {
    return new Date(clean).toISOString();
  } catch {
    return null;
  }
}

function mapIcalStatus(status) {
  if (status === 'CANCELLED') return 'cancelled';
  if (status === 'TENTATIVE') return 'tentative';
  return 'confirmed';
}

function decodeIcalText(str) {
  return str
    .replace(/\\n/g, '\n')
    .replace(/\\,/g, ',')
    .replace(/\\;/g, ';')
    .replace(/\\\\/g, '\\')
    .trim();
}

export async function syncCalendars(account, workspaceId, emitCalendarPayload) {
  const rangeStart = new Date();
  const rangeEnd = addDays(rangeStart, LOOKAHEAD_DAYS);

  let principalPath;
  try {
    principalPath = await discoverPrincipal(account.email, account.password);
  } catch (err) {
    console.error(`[calendar-sync] principal discovery failed for ${account.email}: ${err.message}`);
    return;
  }

  let calendarHomePath;
  try {
    calendarHomePath = await discoverCalendarHome(account.email, account.password, principalPath);
  } catch (err) {
    console.error(`[calendar-sync] calendar home discovery failed: ${err.message}`);
    return;
  }

  let calendars;
  try {
    calendars = await listCalendars(account.email, account.password, calendarHomePath);
  } catch (err) {
    console.error(`[calendar-sync] calendar list failed: ${err.message}`);
    return;
  }

  for (const calendar of calendars) {
    try {
      const icalBlocks = await fetchCalendarEvents(
        account.email,
        account.password,
        calendar.id,
        rangeStart,
        rangeEnd
      );

      const events = icalBlocks
        .map(parseIcalEvent)
        .filter(Boolean);

      if (events.length === 0) continue;

      await emitCalendarPayload({
        type: 'calendar',
        workspaceId,
        accountId: account.id,
        calendarId: calendar.id,
        calendarName: calendar.name,
        sourceProvider: 'calendar_icloud',
        events
      });
      console.log(`[calendar-sync] ${account.email} / ${calendar.name}: emitted=${events.length}`);
    } catch (err) {
      console.error(`[calendar-sync] failed for calendar ${calendar.name}: ${err.message}`);
    }
  }
}
