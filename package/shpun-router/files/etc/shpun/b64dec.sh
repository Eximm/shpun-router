#!/bin/sh
# Minimal base64 decoder for ss:// payloads, no external deps.
# Usage: echo "YWVzLTEyOC1nYw==" | /etc/shpun/b64dec.sh

b64chars='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

awk -v tbl="$b64chars" '
function val(c,   p) {
	p = index(tbl, c)
	return (p ? p - 1 : -1)
}

{
	gsub(/[^A-Za-z0-9+\/=]/, "", $0)

	out = ""
	for (i = 1; i <= length($0); i += 4) {
		c1 = substr($0, i, 1)
		c2 = substr($0, i+1, 1)
		c3 = substr($0, i+2, 1)
		c4 = substr($0, i+3, 1)

		v1 = val(c1); v2 = val(c2)
		v3 = (c3 == "=" ? -1 : val(c3))
		v4 = (c4 == "=" ? -1 : val(c4))

		b1 = (v1 << 2) | (v2 >> 4)
		b2 = ((v2 & 15) << 4) | (v3 < 0 ? 0 : (v3 >> 2))
		b3 = ((v3 & 3) << 6) | (v4 < 0 ? 0 : v4)

		out = out sprintf("%c", b1)
		if (v3 >= 0)
			out = out sprintf("%c", b2)
		if (v4 >= 0)
			out = out sprintf("%c", b3)
	}
	printf "%s", out
}
'
