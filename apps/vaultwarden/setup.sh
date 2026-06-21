#!/bin/bash
# setup.sh — Vaultwarden (gestionnaire de mots de passe)
set -euo pipefail
echo "→ Préparation de Vaultwarden..."

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/${CALEOPE_APP_ID}"
DATA_DIR="${CALEOPE_BASE_DIR}/app-data/vaultwarden"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${DATA_DIR}/data"

# ── Secrets ─────────────────────────────────────────────────────────────────
# Admin token : argon2 hash requis depuis Vaultwarden 1.28
# Fallback vers token hex si argon2 non disponible sur l'hôte
ADMIN_TOKEN_PLAIN=$(openssl rand -hex 32)
if command -v argon2 >/dev/null 2>&1; then
    SALT=$(openssl rand -hex 8)
    ADMIN_TOKEN_HASH=$(echo -n "${ADMIN_TOKEN_PLAIN}" | argon2 "${SALT}" -e -id -k 65536 -t 3 -p 4 2>/dev/null || echo "")
else
    ADMIN_TOKEN_HASH="${ADMIN_TOKEN_PLAIN}"
fi

# ── SMTP (global Caleope) ────────────────────────────────────────────────────
SMTP_HOST="${CALEOPE_SMTP_HOST:-}"
SMTP_PORT="${CALEOPE_SMTP_PORT:-587}"
SMTP_USER="${CALEOPE_SMTP_USER:-}"
SMTP_PASS="${CALEOPE_SMTP_PASS:-}"
SMTP_FROM="${CALEOPE_SMTP_FROM:-noreply@${CALEOPE_DOMAIN}}"

SMTP_BLOCK=""
if [ -n "${SMTP_HOST}" ]; then
    SMTP_BLOCK="SMTP_HOST=${SMTP_HOST}
SMTP_PORT=${SMTP_PORT}
SMTP_USERNAME=${SMTP_USER}
SMTP_PASSWORD=${SMTP_PASS}
SMTP_FROM=${SMTP_FROM}
SMTP_SECURITY=starttls"
fi

REQUIRE_EMAIL_CONFIRMATION="false"
[ -n "${SMTP_HOST}" ] && REQUIRE_EMAIL_CONFIRMATION="true"

cat > "${CONFIG_DIR}/secrets.env" << EOF
# Vaultwarden
ADMIN_TOKEN=${ADMIN_TOKEN_HASH}
DOMAIN=https://${CALEOPE_DOMAIN}
SIGNUPS_ALLOWED=true
SIGNUPS_VERIFY=${REQUIRE_EMAIL_CONFIRMATION}
INVITATIONS_ALLOWED=true
WEBSOCKET_ENABLED=true
ROCKET_PORT=80

# SMTP
${SMTP_BLOCK}

# Token brut (pour l'accès admin — à conserver)
_ADMIN_TOKEN_PLAIN=${ADMIN_TOKEN_PLAIN}
EOF
chmod 600 "${CONFIG_DIR}/secrets.env"

# ── CA bundle + AUTHENTIK_DOMAIN ────────────────────────────────────────────────
# Vaultwarden (Rust/OpenSSL) doit valider le cert TLS d'Authentik (auto-signé).
# On crée un bundle = CAs système + cert Authentik, monté dans le container.
# AUTHENTIK_DOMAIN est écrit dans secrets.env pour l'interpolation compose (extra_hosts).
BASE_DOMAIN=$(echo "${CALEOPE_DOMAIN}" | cut -d. -f2-)
_AK_DOMAIN_EARLY=$(grep "^AUTHENTIK_DOMAIN=" "${CALEOPE_BASE_DIR}/app-config/authentik/secrets.env" 2>/dev/null | cut -d= -f2- || true)
[ -n "${_AK_DOMAIN_EARLY}" ] || _AK_DOMAIN_EARLY="authentik.${BASE_DOMAIN}"
# Écrire dans app.env (projet compose) AVANT docker up pour l'interpolation extra_hosts
# (generateCompose tourne avant setup.sh → secrets.env vide → app.env sans AUTHENTIK_DOMAIN)
echo "AUTHENTIK_DOMAIN=${_AK_DOMAIN_EARLY}" >> "${CALEOPE_APP_DIR}/app.env"

AK_CERT="${CALEOPE_BASE_DIR}/data/traefik/certs/authentik.crt"
if [ -f "${AK_CERT}" ]; then
    cat /etc/ssl/certs/ca-certificates.crt "${AK_CERT}" > "${CONFIG_DIR}/ca-bundle.pem"
else
    cp /etc/ssl/certs/ca-certificates.crt "${CONFIG_DIR}/ca-bundle.pem"
fi
chmod 644 "${CONFIG_DIR}/ca-bundle.pem"

# ── Authentik SSO (OIDC natif) ────────────────────────────────────────────────
# Vaultwarden supporte nativement l'OIDC depuis v1.30 → bouton "Se connecter
# avec SSO" dans l'UI + support des clients Bitwarden (mobile, extension).
# On crée un provider OAuth2/OIDC dans Authentik (pas un proxy ForwardAuth).
if [ -d "${CALEOPE_BASE_DIR}/apps-installed/authentik" ]; then
    AK_SECRETS="${CALEOPE_BASE_DIR}/app-config/authentik/secrets.env"
    if [ -f "${AK_SECRETS}" ]; then
        AK_TOKEN=$(grep "^AUTHENTIK_BOOTSTRAP_TOKEN=" "${AK_SECRETS}" | cut -d= -f2-)
        AK_DOMAIN=$(grep "^AUTHENTIK_DOMAIN=" "${AK_SECRETS}" | cut -d= -f2-)
        if [ -n "${AK_TOKEN}" ] && [ -n "${AK_DOMAIN}" ]; then
            AK_PORT=$(python3 -c "import json; d=json.load(open('${CALEOPE_BASE_DIR}/runtime/apps/authentik.json')); print(next((p['host'] for p in d.get('ports',[]) if p['name']=='web'), 9000))" 2>/dev/null)
            AK_PORT="${AK_PORT:-9000}"
            AK_BASE="http://localhost:${AK_PORT}/api/v3"
            AK_HA="Authorization: Bearer ${AK_TOKEN}"
            AK_HJ="Content-Type: application/json"

            AUTH_FLOW=$(curl -s --max-time 10 -H "${AK_HA}" \
                "${AK_BASE}/flows/instances/?slug=default-provider-authorization-implicit-consent" \
                | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['results'][0]['pk'] if d['results'] else '')" 2>/dev/null || echo "")
            INVAL_FLOW=$(curl -s --max-time 10 -H "${AK_HA}" \
                "${AK_BASE}/flows/instances/?slug=default-provider-invalidation-flow" \
                | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['results'][0]['pk'] if d['results'] else '')" 2>/dev/null || echo "")

            if [ -n "${AUTH_FLOW}" ] && [ -n "${INVAL_FLOW}" ]; then
                # Clé de signature RSA par défaut d'Authentik (nécessaire pour RS256 / JWKS)
                SIGNING_KEY=$(curl -s --max-time 10 -H "${AK_HA}" \
                    "${AK_BASE}/crypto/certificatekeypairs/?has_key=true" \
                    | python3 -c "import sys,json; d=json.load(sys.stdin); r=d.get('results',[]); print(r[0]['pk'] if r else '')" 2>/dev/null || echo "")

                # Chercher un provider OAuth2 existant (idempotent)
                EXISTING=$(curl -s --max-time 10 -H "${AK_HA}" \
                    "${AK_BASE}/providers/oauth2/?search=Vaultwarden" \
                    | python3 -c "
import sys,json
d=json.load(sys.stdin)
r=d.get('results',[])
if r:
    print(json.dumps({'pk':r[0]['pk'],'cid':r[0]['client_id'],'cs':r[0]['client_secret'],'sk':r[0].get('signing_key')}))
" 2>/dev/null || echo "")

                if [ -n "${EXISTING}" ]; then
                    PROV_PK=$(echo "${EXISTING}" | python3 -c "import sys,json; print(json.load(sys.stdin)['pk'])")
                    SSO_CLIENT_ID=$(echo "${EXISTING}" | python3 -c "import sys,json; print(json.load(sys.stdin)['cid'])")
                    SSO_CLIENT_SECRET=$(echo "${EXISTING}" | python3 -c "import sys,json; print(json.load(sys.stdin)['cs'])")
                    EXISTING_SK=$(echo "${EXISTING}" | python3 -c "import sys,json; v=json.load(sys.stdin).get('sk'); print(v if v else '')" 2>/dev/null || echo "")
                    # Patch OIDC natif : corriger signing_key + redirect_uris si migration depuis ForwardAuth
                    # (l'ancien setup ForwardAuth laissait des redirect_uris /outpost.goauthentik.io/callback)
                    REDIRECT_URI="https://${CALEOPE_DOMAIN}/identity/connect/oidc-signin"
                    REDIRECT_SSO="https://${CALEOPE_DOMAIN}/sso-connector.html"
                    PATCH_JSON="{\"redirect_uris\":[{\"matching_mode\":\"strict\",\"url\":\"${REDIRECT_URI}\"},{\"matching_mode\":\"strict\",\"url\":\"${REDIRECT_SSO}\"}]"
                    if [ -z "${EXISTING_SK}" ] && [ -n "${SIGNING_KEY}" ]; then
                        PATCH_JSON="${PATCH_JSON},\"signing_key\":\"${SIGNING_KEY}\""
                    fi
                    PATCH_JSON="${PATCH_JSON}}"
                    curl -s --max-time 10 -X PATCH -H "${AK_HA}" -H "${AK_HJ}" \
                        "${AK_BASE}/providers/oauth2/${PROV_PK}/" \
                        -d "${PATCH_JSON}" >/dev/null 2>&1 || true
                    echo "  ✓ redirect_uris et signing_key patchées (migration ForwardAuth → OIDC natif)"
                else
                    REDIRECT_URI="https://${CALEOPE_DOMAIN}/identity/connect/oidc-signin"
                    SIGN_KEY_JSON=$([ -n "${SIGNING_KEY}" ] && echo ",\"signing_key\":\"${SIGNING_KEY}\"" || echo "")
                    PROV_RESP=$(curl -s --max-time 10 -X POST -H "${AK_HA}" -H "${AK_HJ}" \
                        "${AK_BASE}/providers/oauth2/" \
                        -d "{\"name\":\"Vaultwarden\",\"authorization_flow\":\"${AUTH_FLOW}\",\"invalidation_flow\":\"${INVAL_FLOW}\",\"client_type\":\"confidential\",\"redirect_uris\":[{\"matching_mode\":\"strict\",\"url\":\"${REDIRECT_URI}\"}],\"sub_mode\":\"hashed_user_id\",\"include_claims_in_id_token\":true${SIGN_KEY_JSON}}" \
                        2>/dev/null || echo "")
                    PROV_PK=$(echo "${PROV_RESP}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('pk',''))" 2>/dev/null || echo "")
                    SSO_CLIENT_ID=$(echo "${PROV_RESP}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('client_id',''))" 2>/dev/null || echo "")
                    SSO_CLIENT_SECRET=$(echo "${PROV_RESP}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('client_secret',''))" 2>/dev/null || echo "")
                fi

                if [ -n "${PROV_PK}" ] && [ -n "${SSO_CLIENT_ID}" ]; then
                    # Chercher l'application existante liée à ce provider (filtrage client-side
                    # car l'API Authentik ne supporte pas ?provider=pk comme filtre)
                    APP_SLUG=$(curl -s --max-time 10 -H "${AK_HA}" \
                        "${AK_BASE}/core/applications/" \
                        | python3 -c "
import sys,json
d=json.load(sys.stdin)
pk=int('${PROV_PK}')
r=[a for a in d.get('results',[]) if a.get('provider')==pk]
print(r[0]['slug'] if r else '')
" 2>/dev/null || echo "")

                    if [ -z "${APP_SLUG}" ]; then
                        # Créer l'application Authentik avec slug canonique
                        APP_RESP=$(curl -s --max-time 10 -X POST -H "${AK_HA}" -H "${AK_HJ}" \
                            "${AK_BASE}/core/applications/" \
                            -d "{\"name\":\"Vaultwarden\",\"slug\":\"vaultwarden\",\"provider\":${PROV_PK},\"meta_launch_url\":\"https://${CALEOPE_DOMAIN}/\"}" \
                            2>/dev/null || echo "")
                        APP_SLUG=$(echo "${APP_RESP}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('slug','vaultwarden'))" 2>/dev/null || echo "vaultwarden")
                    fi

                    # Port CONTAINER d'Authentik (pour accès Docker-to-Docker sans TLS)
                    # On utilise p['container'] et non p['host'] (le host port ne répond pas
                    # depuis le réseau Docker interne — seul le port container est accessible)
                    AK_HTTP_PORT=$(python3 -c "
import json
d=json.load(open('${CALEOPE_BASE_DIR}/runtime/apps/authentik.json'))
print(next((p['container'] for p in d.get('ports',[]) if p['name']=='web'), 9000))
" 2>/dev/null || echo "9000")

                    # Sidecar proxy Python : proxie vers Authentik avec X-Forwarded headers
                    # pour que le discovery doc retourne les URLs publiques HTTPS, puis
                    # réécrit les URLs backend (token, jwks, userinfo...) vers le proxy interne.
                    # authorization_endpoint reste l'URL publique pour le browser redirect.
                    #
                    # Problème fondamental (Vaultwarden v1.36.0 + openidconnect crate) :
                    #   - Le discovery doc doit avoir issuer == URL proxy (validation discovery)
                    #   - Le JWT id_token d'Authentik a iss == domaine public Authentik
                    #   - vw_id_token_verifier() vérifie iss == issuer du discovery → MISMATCH
                    #   - SSO_JWT_ISSUER n'existe pas en v1.36.0 (c'est une constante interne)
                    # Solution : le proxy re-signe l'id_token avec une clé RSA locale et
                    # expose cette clé via /jwks/. L'issuer est réécrit vers l'URL proxy.
                    # Clé RSA générée une fois à l'installation (pure Python, sans dépendances).
                    echo "  → Génération clé RSA proxy JWT (peut prendre ~30s)..."
                    RSA_KEY_JSON=$(python3 << 'PYGENRSA'
import os, json

def is_prime(n, k=20):
    if n < 2: return False
    if n in (2, 3): return True
    if n % 2 == 0: return False
    r, d = 0, n - 1
    while d % 2 == 0:
        r += 1; d //= 2
    for _ in range(k):
        a = int.from_bytes(os.urandom(4), 'big') % (n - 3) + 2
        x = pow(a, d, n)
        if x in (1, n - 1): continue
        for _ in range(r - 1):
            x = pow(x, 2, n)
            if x == n - 1: break
        else: return False
    return True

def gen_prime(bits):
    while True:
        nb = os.urandom(bits // 8)
        n = int.from_bytes(nb, 'big') | (1 << (bits - 1)) | 1
        if is_prime(n): return n

def modinv(a, m):
    old_r, r, old_s, s = m, a, 0, 1
    while r != 0:
        q = old_r // r
        old_r, r = r, old_r - q * r
        old_s, s = s, old_s - q * s
    return old_s % m

e = 65537
p = gen_prime(1024)
q = gen_prime(1024)
while q == p: q = gen_prime(1024)
n = p * q
phi = (p - 1) * (q - 1)
d = modinv(e, phi)
print(json.dumps({'n': str(n), 'e': str(e), 'd': str(d)}))
PYGENRSA
)
                    RSA_N=$(echo "${RSA_KEY_JSON}" | python3 -c "import sys,json; print(json.load(sys.stdin)['n'])")
                    RSA_E=$(echo "${RSA_KEY_JSON}" | python3 -c "import sys,json; print(json.load(sys.stdin)['e'])")
                    RSA_D=$(echo "${RSA_KEY_JSON}" | python3 -c "import sys,json; print(json.load(sys.stdin)['d'])")

                    cat > "${CONFIG_DIR}/authentik-proxy.py" << PYHEAD
# Constantes générées à l'installation
AK_HOST = "authentik-server"
AK_PORT = ${AK_HTTP_PORT}
AK_DOMAIN = "${AK_DOMAIN}"
PROXY_PORT = 9001
PROXY_HOST = "vaultwarden-ak-proxy"
RSA_N = ${RSA_N}
RSA_E = ${RSA_E}
RSA_D = ${RSA_D}
PYHEAD
                    cat >> "${CONFIG_DIR}/authentik-proxy.py" << 'PYBODY'
import http.server, urllib.request, urllib.error, json, hashlib, base64

def _b64u(data):
    if isinstance(data, int):
        ln = (data.bit_length() + 7) // 8
        data = data.to_bytes(ln, 'big')
    return base64.urlsafe_b64encode(data).rstrip(b'=').decode()

def _b64ud(s):
    return base64.urlsafe_b64decode(s + '=' * (-len(s) % 4))

def _rsa_sign(msg, d, n):
    if isinstance(msg, str): msg = msg.encode()
    h = hashlib.sha256(msg).digest()
    pfx = bytes([0x30,0x31,0x30,0x0d,0x06,0x09,0x60,0x86,0x48,0x01,0x65,0x03,0x04,0x02,0x01,0x05,0x00,0x04,0x20])
    T = pfx + h
    kl = (n.bit_length() + 7) // 8
    em = b'\x00\x01' + b'\xff' * (kl - len(T) - 3) + b'\x00' + T
    return pow(int.from_bytes(em, 'big'), d, n).to_bytes(kl, 'big')

def _resign(token, d, n):
    try:
        p = token.split('.')
        if len(p) != 3: return token
        payload = json.loads(_b64ud(p[1]))
        # Réécrire l'issuer : remplacer le domaine public Authentik par l'URL proxy
        # Ex: https://authentik.example.com/application/o/vaultwarden-sso/
        #  -> http://vaultwarden-ak-proxy:9001/application/o/vaultwarden-sso/
        old_iss = payload.get('iss', '')
        pub = f"https://{AK_DOMAIN}/"
        prx = f"http://{PROXY_HOST}:{PROXY_PORT}/"
        if old_iss.startswith(pub):
            payload['iss'] = old_iss.replace(pub, prx, 1)
        hdr = _b64u(json.dumps({'typ':'JWT','alg':'RS256','kid':'proxy-1'},separators=(',',':')).encode())
        pld = _b64u(json.dumps(payload,separators=(',',':')).encode())
        si = f"{hdr}.{pld}"
        return f"{si}.{_b64u(_rsa_sign(si, d, n))}"
    except Exception:
        return token

JWKS_BODY = json.dumps({"keys":[{
    "kty":"RSA","use":"sig","alg":"RS256","kid":"proxy-1",
    "n":_b64u(RSA_N),"e":_b64u(RSA_E)
}]}).encode()

class ProxyHandler(http.server.BaseHTTPRequestHandler):
    def proxy_request(self, method, body=None):
        # JWKS : retourner notre clé locale (pas Authentik) pour vérifier les JWT re-signés
        if '/jwks/' in self.path:
            self.send_response(200)
            self.send_header('Content-Type','application/json')
            self.send_header('Content-Length',len(JWKS_BODY))
            self.end_headers()
            self.wfile.write(JWKS_BODY)
            return
        url = f"http://{AK_HOST}:{AK_PORT}{self.path}"
        headers = {
            "X-Forwarded-Host": AK_DOMAIN,
            "X-Forwarded-Proto": "https",
            "X-Forwarded-Port": "443",
            "Host": AK_DOMAIN,
        }
        for h in ["Content-Type", "Authorization", "Accept"]:
            if h in self.headers:
                headers[h] = self.headers[h]
        if body:
            headers["Content-Length"] = str(len(body))
        req = urllib.request.Request(url, data=body, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                rb = resp.read()
                ct = resp.headers.get("Content-Type", "")
                if "application/json" in ct and ".well-known/openid-configuration" in self.path:
                    try:
                        doc = json.loads(rb)
                        pub = f"https://{AK_DOMAIN}/"
                        prx = f"http://{PROXY_HOST}:{PROXY_PORT}/"
                        auth_ep = doc.get("authorization_endpoint","")
                        for k,v in doc.items():
                            if isinstance(v,str) and v.startswith(pub):
                                doc[k] = v.replace(pub,prx,1)
                        if auth_ep: doc["authorization_endpoint"] = auth_ep
                        rb = json.dumps(doc,indent=2).encode()
                    except Exception: pass
                elif "application/json" in ct and "/token/" in self.path:
                    # Re-signer l'id_token avec notre clé locale + réécrire l'issuer
                    # pour que Vaultwarden (openidconnect crate) accepte la validation.
                    # Le slug est extrait de l'iss original du JWT (pas du path token endpoint)
                    try:
                        data = json.loads(rb)
                        if "id_token" in data:
                            data["id_token"] = _resign(data["id_token"], RSA_D, RSA_N)
                            rb = json.dumps(data).encode()
                    except Exception: pass
                self.send_response(resp.status)
                skip = {"transfer-encoding","content-encoding","content-length","connection"}
                for h,v in resp.headers.items():
                    if h.lower() not in skip: self.send_header(h,v)
                self.send_header("Content-Length",len(rb))
                self.end_headers()
                self.wfile.write(rb)
        except urllib.error.URLError as e:
            self.send_error(502, str(e))
    def do_GET(self): self.proxy_request("GET")
    def do_POST(self):
        cl = int(self.headers.get("Content-Length",0))
        self.proxy_request("POST", self.rfile.read(cl) if cl else None)
    def log_message(self, *a): pass

http.server.HTTPServer(("0.0.0.0",PROXY_PORT),ProxyHandler).serve_forever()
PYBODY

                    # Injecter la config SSO dans secrets.env
                    # SSO_AUTHORITY = proxy nginx interne (qui ajoute X-Forwarded headers)
                    # SSO_JWT_ISSUER = URL publique HTTPS (override pour validation JWT
                    #   et check issuer dans le discovery)
                    cat >> "${CONFIG_DIR}/secrets.env" << SSOENV

# SSO Authentik (OIDC natif — bouton "Se connecter avec SSO" dans l'UI)
SSO_ENABLED=true
SSO_ONLY=false
SSO_PROVIDER_NAME=Authentik
SSO_AUTHORITY=http://vaultwarden-ak-proxy:9001/application/o/${APP_SLUG}/
SSO_CLIENT_ID=${SSO_CLIENT_ID}
SSO_CLIENT_SECRET=${SSO_CLIENT_SECRET}
SSOENV

                    echo "  ✓ Vaultwarden OIDC configuré dans Authentik (slug=${APP_SLUG}, client_id=${SSO_CLIENT_ID})"
                fi
            fi
        fi
    fi
fi

# ── post-install.txt ─────────────────────────────────────────────────────────
cat > "${CALEOPE_APP_DIR}/post-install.txt" << EOF

  ┌──────────────────────────────────────────────────────────────────┐
  │               Vaultwarden — Gestionnaire de mots de passe        │
  ├──────────────────────────────────────────────────────────────────┤
  │  Application : https://${CALEOPE_DOMAIN}/                        │
  │                                                                  │
  │  Interface admin :                                               │
  │    URL   : https://${CALEOPE_DOMAIN}/admin                       │
  │    Token : ${ADMIN_TOKEN_PLAIN}
  │                                                                  │
  │  Connexion SSO : bouton "Se connecter avec SSO" dans l'UI        │
  │    → Utilise Authentik (OIDC). Les comptes locaux restent        │
  │    disponibles en parallèle (SSO_ONLY=false).                    │
  │                                                                  │
  │  Extension navigateur : Bitwarden (compatible Vaultwarden)       │
  │    → Entrer https://${CALEOPE_DOMAIN}/ comme URL serveur         │
  │                                                                  │
  │  Secrets dans : app-config/${CALEOPE_APP_ID}/secrets.env         │
  └──────────────────────────────────────────────────────────────────┘
EOF

echo ""
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║          Vaultwarden — Token admin                   ║"
echo "  ╠══════════════════════════════════════════════════════╣"
echo "  ║  URL admin : https://${CALEOPE_DOMAIN}/admin"
echo "  ║  Token     : ${ADMIN_TOKEN_PLAIN}"
echo "  ╚══════════════════════════════════════════════════════╝"
echo ""
echo "✓ Vaultwarden configuré"
