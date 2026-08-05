#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$SCRIPT_DIR/config.yaml"
REDIRECT_PORT=8765
REDIRECT_URI="http://localhost:$REDIRECT_PORT"
SCOPE="https://www.googleapis.com/auth/gmail.readonly"

creds_file=$(sed -n '/^gmail:/,/^[a-z]/{s/^ *credentials_file: *"\(.*\)"/\1/p}' "$CONFIG" | head -1)
creds_file="${creds_file/#\~/$HOME}"

if [[ -z "$creds_file" || ! -f "$creds_file" ]]; then
    echo "Error: credentials_file not found."
    echo "Add to config.yaml:"
    echo '  gmail:'
    echo '    credentials_file: "~/.config/tsk/work_credentials.json"'
    echo '    token_file: "~/.config/nook/gmail_token.json"'
    exit 1
fi

token_file=$(sed -n '/^gmail:/,/^[a-z]/{s/^ *token_file: *"\(.*\)"/\1/p}' "$CONFIG" | head -1)
token_file="${token_file/#\~/$HOME}"
mkdir -p "$(dirname "$token_file")"

client_id=$(jq -r '.installed.client_id' "$creds_file")
client_secret=$(jq -r '.installed.client_secret' "$creds_file")

auth_url="https://accounts.google.com/o/oauth2/v2/auth"
auth_url+="?client_id=$client_id"
auth_url+="&redirect_uri=$(printf '%s' "$REDIRECT_URI" | jq -Rr @uri)"
auth_url+="&response_type=code"
auth_url+="&scope=$(printf '%s' "$SCOPE" | jq -Rr @uri)"
auth_url+="&access_type=offline"
auth_url+="&prompt=consent"

echo "Opening browser for Gmail authorization..."
xdg-open "$auth_url" &>/dev/null &

echo "Waiting for authorization..."
code=$(timeout 300 env NOOK_PORT="$REDIRECT_PORT" python3 -c "
import os
from http.server import HTTPServer, BaseHTTPRequestHandler
import urllib.parse

port = int(os.environ['NOOK_PORT'])

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        if 'code' in q:
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.end_headers()
            self.wfile.write(b'<h1>Success!</h1><p>You can close this window.</p>')
            print(q['code'][0], flush=True)
        else:
            self.send_response(400)
            self.end_headers()
    def log_message(self, *a): pass

HTTPServer(('', port), Handler).handle_request()
") || { echo "Error: Authorization timed out"; exit 1; }

[[ -z "$code" ]] && { echo "Error: No authorization code received"; exit 1; }

response=$(curl -s -X POST "https://oauth2.googleapis.com/token" \
    -d "client_id=$client_id" \
    -d "client_secret=$client_secret" \
    -d "code=$code" \
    -d "redirect_uri=$REDIRECT_URI" \
    -d "grant_type=authorization_code") || {
    echo "Error: Token exchange failed"
    exit 1
}

IFS=$'\t' read -r access_token refresh_token expires_in < <(
    echo "$response" | jq -r '[.access_token // empty, .refresh_token // empty, (.expires_in // 3600 | tostring)] | @tsv'
)

if [[ -z "$access_token" || -z "$refresh_token" ]]; then
    echo "Error: Invalid token response"
    echo "$response" | jq .
    exit 1
fi

expiry=$(date -d "+${expires_in} seconds" -Iseconds)

jq -n --arg at "$access_token" --arg rt "$refresh_token" --arg exp "$expiry" \
    '{access_token: $at, refresh_token: $rt, expiry: $exp}' > "$token_file"

chmod 600 "$token_file"
echo "Token saved to $token_file"
