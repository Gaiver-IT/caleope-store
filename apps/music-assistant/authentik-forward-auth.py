#!/usr/bin/env python3
"""Register a Caleope app with Authentik before enabling Traefik ForwardAuth."""

import json
import sys
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


def main(base_dir: Path, domain: str, slug: str, name: str) -> None:
    config = base_dir / "app-config/authentik/secrets.env"
    token = next(
        (line.partition("=")[2].strip() for line in config.read_text().splitlines()
         if line.startswith("AUTHENTIK_BOOTSTRAP_TOKEN=")),
        "",
    )
    if not token:
        raise RuntimeError("Jeton d'administration Authentik introuvable")

    runtime = json.loads((base_dir / "runtime/apps/authentik.json").read_text())
    port = next((p["host"] for p in runtime.get("ports", []) if p.get("name") == "web"), 9000)
    api = f"http://127.0.0.1:{port}/api/v3"

    def request(path: str, method: str = "GET", payload=None):
        data = None if payload is None else json.dumps(payload).encode()
        headers = {"Authorization": f"Bearer {token}"}
        if data is not None:
            headers["Content-Type"] = "application/json"
        try:
            with urlopen(Request(api + path, data=data, headers=headers, method=method), timeout=15) as response:
                return json.load(response)
        except HTTPError as exc:
            raise RuntimeError(f"API Authentik : HTTP {exc.code} sur {path}") from exc
        except URLError as exc:
            raise RuntimeError(f"API Authentik inaccessible sur {path}: {exc.reason}") from exc

    def first(path: str):
        results = request(path).get("results", [])
        if not results:
            raise RuntimeError(f"Objet Authentik absent : {path}")
        return results[0]

    auth_flow = first("/flows/instances/?slug=default-provider-authorization-implicit-consent")["pk"]
    invalidation_flow = first("/flows/instances/?slug=default-provider-invalidation-flow")["pk"]
    external_host = f"https://{domain}"
    providers = request("/providers/proxy/?page_size=100")["results"]
    matching = [p for p in providers if p.get("external_host", "").rstrip("/") == external_host]
    if len(matching) > 1:
        raise RuntimeError(f"Plusieurs fournisseurs Authentik pour {domain}")
    if matching:
        provider = matching[0]
        if provider.get("mode") != "forward_single":
            raise RuntimeError(f"Mode du fournisseur Authentik inattendu pour {domain}")
        provider_pk = provider["pk"]
    else:
        provider_pk = request("/providers/proxy/", "POST", {
            "name": name, "authorization_flow": auth_flow,
            "invalidation_flow": invalidation_flow,
            "external_host": external_host, "mode": "forward_single",
        })["pk"]

    applications = request("/core/applications/?page_size=100")["results"]
    matching = [app for app in applications if app.get("slug") == slug]
    if len(matching) > 1:
        raise RuntimeError(f"Plusieurs applications Authentik pour {slug}")
    if matching:
        if matching[0].get("provider") != provider_pk:
            raise RuntimeError(f"L'application Authentik {slug} utilise un autre fournisseur")
    else:
        request("/core/applications/", "POST", {
            "name": name, "slug": slug, "provider": provider_pk,
            "meta_launch_url": external_host + "/",
        })

    outpost_pk = first("/outposts/instances/?managed=goauthentik.io%2Foutposts%2Fembedded")["pk"]
    outpost = request(f"/outposts/instances/{outpost_pk}/")
    assigned = outpost.get("providers", [])
    if provider_pk not in assigned:
        request(f"/outposts/instances/{outpost_pk}/", "PATCH", {
            "providers": assigned + [provider_pk],
        })
    verified = request(f"/outposts/instances/{outpost_pk}/")
    if provider_pk not in verified.get("providers", []):
        raise RuntimeError(f"Fournisseur {slug} non associé à l'outpost Authentik")
    print(f"✓ Authentik ForwardAuth prêt pour {domain}")


if __name__ == "__main__":
    try:
        main(Path(sys.argv[1]), *sys.argv[2:5])
    except (OSError, ValueError, KeyError, IndexError, RuntimeError) as error:
        print(f"✗ Configuration ForwardAuth interrompue : {error}", file=sys.stderr)
        sys.exit(1)
