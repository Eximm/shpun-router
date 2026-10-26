// Input and output contain metadata only; never pass a subscription URL here.
import { readfile } from 'fs';

function http_date(value) {
	let m = match(value || '', /^[A-Za-z]{3}, ([0-9]{2}) ([A-Za-z]{3}) ([0-9]{4}) ([0-9]{2}):([0-9]{2}):([0-9]{2}) GMT$/);
	if (!m) return null;
	let months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
	let month = index(months, m[2]), year = int(m[3]), day = int(m[1]);
	let hour = int(m[4]), minute = int(m[5]), second = int(m[6]);
	if (month < 0 || year < 2025 || year > 2100 || hour > 23 || minute > 59 || second > 59) return null;
	let leap = (year % 4 == 0 && (year % 100 != 0 || year % 400 == 0));
	let lengths = [31, leap ? 29 : 28,31,30,31,30,31,31,30,31,30,31];
	if (day < 1 || day > lengths[month]) return null;
	let days = day - 1;
	for (let y = 1970; y < year; y++) days += (y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)) ? 366 : 365;
	for (let j = 0; j < month; j++) days += lengths[j];
	return days * 86400 + hour * 3600 + minute * 60 + second;
}

function notice_state(headers, now, fingerprint, previous) {
	let result = { version: 1, status: 'unknown', expires_at: null, checked_at: now,
		source_available: false, fingerprint: fingerprint || '', last_confirmed_at: 0 };
	// Only the final HTTP response counts (ignore proxy CONNECT / informational headers).
	let status = 0, info = [], dates = [], age = 0;
	for (let line in split(headers || '', '\n')) {
		line = trim(line);
		let code = match(line, /^HTTP\/[0-9.]+ ([0-9]{3})( |$)/);
		if (code) { status = int(code[1]); info = []; dates = []; age = 0; continue; }
		let h = match(line, /^([^:]+):\s*(.*)$/);
		if (!h) continue;
		let name = lc(h[1]);
		if (name == 'subscription-userinfo') push(info, h[2]);
		if (name == 'date') push(dates, h[2]);
		if (name == 'age') age = match(h[2], /^[0-9]+$/) ? int(h[2]) : 999999;
	}
	let expires = [];
	if (length(info) == 1) {
		for (let field in split(info[0], ';')) {
			let pair = match(trim(field), /^expire\s*=\s*([0-9]+)$/i);
			if (pair) push(expires, pair[1]);
			else if (match(trim(field), /^expire\s*=/i)) push(expires, 'invalid');
		}
	}
	let server_now = length(dates) == 1 ? http_date(dates[0]) : null;
	let clock_ok = server_now != null && now >= server_now - 300 && now <= server_now + 300;
	if (status == 200 && length(expires) == 1 && expires[0] != 'invalid' &&
	    length(expires[0]) <= 11 && int(expires[0]) <= 32503680000 && clock_ok && age <= 300) {
		result.expires_at = int(expires[0]);
		result.status = result.expires_at > 0 && result.expires_at <= server_now ? 'expired' : 'active';
		result.source_available = true;
		result.last_confirmed_at = now;
	} else if (previous && previous.fingerprint == result.fingerprint && previous.source_available == true) {
		// Preserve a last-confirmed timestamp for diagnostics, never keep a captive state on transport failure.
		result.expires_at = previous.expires_at;
		result.last_confirmed_at = previous.last_confirmed_at || 0;
	}
	return result;
}

let input;
try { input = json(readfile('/dev/stdin')); } catch (e) { exit(1); }
if (type(input) != 'object' || type(input.headers) != 'string' ||
    type(input.now) != 'int' || input.now < 0 || type(input.fingerprint) != 'string') exit(1);
print(sprintf('%J\n', notice_state(input.headers, input.now, input.fingerprint, input.previous)));
