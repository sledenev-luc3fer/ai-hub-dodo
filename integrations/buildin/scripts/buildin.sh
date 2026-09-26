#!/bin/bash
# Buildin UI API CLI — HTTP-клиент для UI API (buildin.ai/api/)
#
# Usage: ./buildin.sh <METHOD> <ENDPOINT> [JSON_BODY]
# Example: ./buildin.sh GET /api/users/me
#          ./buildin.sh GET /api/docs/<page_id>
#          ./buildin.sh POST /api/records/transactions '{"requestId":"...","transactions":[...]}'
#
# Auth: Bearer JWT via BUILDIN_UI_TOKEN in .env
# Login: /ai-hub:buildin-login
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Source hub-meta/scripts/load-env.sh from either marketplace layout
# (<root>/integrations/<plugin>/scripts/) or Claude Code plugin cache
# (<cache>/<marketplace>/<plugin>/<version>/scripts/, resolved by globbing the
# sibling hub-meta versions and taking the highest, with $CLAUDE_PLUGIN_ROOT
# as a last resort).
_hub_load_env_sh="$SCRIPT_DIR/../../hub-meta/scripts/load-env.sh"
[[ -f "$_hub_load_env_sh" ]] || _hub_load_env_sh=$(ls "$SCRIPT_DIR"/../../../hub-meta/*/scripts/load-env.sh 2>/dev/null | sort -V | tail -1)
[[ -f "$_hub_load_env_sh" ]] || _hub_load_env_sh=$(ls "${CLAUDE_PLUGIN_ROOT:-/dev/null}"/../../hub-meta/*/scripts/load-env.sh 2>/dev/null | sort -V | tail -1)
[[ -f "$_hub_load_env_sh" ]] || { echo "Error: hub-meta/scripts/load-env.sh not found (marketplace and plugin-cache layouts checked)" >&2; exit 1; }
# shellcheck source=../../hub-meta/scripts/load-env.sh
source "$_hub_load_env_sh"
unset _hub_load_env_sh
hub_load_env "$SCRIPT_DIR"

BUILDIN_BASE_URL="https://buildin.ai"

# Check token
if [[ -z "$BUILDIN_UI_TOKEN" ]]; then
    echo "Error: BUILDIN_UI_TOKEN not set. Run /ai-hub:buildin-login first." >&2
    exit 1
fi

METHOD="${1:-GET}"
ENDPOINT="${2}"
BODY="$3"

if [[ -z "$ENDPOINT" ]]; then
    echo "Usage: ./buildin.sh <METHOD> <ENDPOINT> [JSON_BODY]" >&2
    echo "Example: ./buildin.sh GET /api/users/me" >&2
    echo "         ./buildin.sh GET /api/docs/<page_id>" >&2
    exit 1
fi

CURL_ARGS=(
    -s
    -X "$METHOD"
    -H "Authorization: Bearer $BUILDIN_UI_TOKEN"
    -H "Content-Type: application/json"
    -H "x-platform: web-cookie"
    -H "x-app-origin: web"
    -H "x-product: buildin"
    -H "app_version_name: 1.146.0"
)

if [[ -n "$BODY" ]]; then
    CURL_ARGS+=(-d "$BODY")
fi

response=$(curl "${CURL_ARGS[@]}" -w "\n%{http_code}" "${BUILDIN_BASE_URL}${ENDPOINT}")

http_code=$(echo "$response" | tail -n1)
body=$(echo "$response" | sed '$d')

if [[ "$http_code" == "401" ]]; then
    echo "Error: Token expired. Run /ai-hub:buildin-login to re-authenticate." >&2
    exit 1
fi

if [[ "$http_code" -ge 400 ]]; then
    echo "Error: HTTP $http_code" >&2
    echo "$body" >&2
    exit 1
fi

# UI API кладёт настоящий статус не в HTTP, а в поле `code` тела: на
# несуществующий документ приходит HTTP 200 и {"code":3005,"msg":"Document not
# found"}. Без этой проверки вызывающий получает тело ошибки как успешный ответ
# и идёт дальше — уже с ним вместо данных.
#
# Статусом считается только верхнеуровневый `code` у JSON-объекта. Ответ без
# этого поля, не-JSON и любое тело при отсутствии python3 проходят как раньше:
# часть ответов статуса не несёт, а клиент обязан оставаться рабочим без
# python3 — ровно как он уже работает без jq.
if command -v python3 &> /dev/null; then
    api_error=$(printf '%s' "$body" | python3 -c '
import json, sys
try:
    payload = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if not isinstance(payload, dict) or "code" not in payload:
    sys.exit(0)
code = payload["code"]
if isinstance(code, bool):
    sys.exit(0)
if isinstance(code, str) and code.strip().lstrip("-").isdigit():
    code = int(code)
if not isinstance(code, int) or 200 <= code < 300:
    sys.exit(0)
print("%s: %s" % (code, payload.get("msg") or payload.get("message") or "no message"))
' 2>/dev/null)
    if [[ -n "$api_error" ]]; then
        echo "Error: Buildin API code $api_error" >&2
        exit 1
    fi
fi

if command -v jq &> /dev/null; then
    echo "$body" | jq . 2>/dev/null || echo "$body"
else
    echo "$body"
fi
