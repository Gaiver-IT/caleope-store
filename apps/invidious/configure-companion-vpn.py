#!/usr/bin/env python3
"""Adapt the rendered Compose for a Companion sharing an existing VPN netns."""

import re
import sys
from pathlib import Path


def configure(compose: str, container: str, network: str) -> str:
    safe = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9_.-]*$")
    if not safe.fullmatch(container) or not safe.fullmatch(network):
        raise ValueError("Nom de conteneur ou de réseau VPN invalide")

    def replace_once(old: str, new: str) -> None:
        nonlocal compose
        if compose.count(old) != 1:
            raise ValueError(f"Structure Compose inattendue pour {old.strip()[:40]}")
        compose = compose.replace(old, new, 1)

    replace_once(
        "    networks:\n      - caleope-public\n      - caleope-internal\n",
        f"    networks:\n      - caleope-public\n      - caleope-internal\n      - {network}\n",
    )
    replace_once(
        "  invidious-companion:\n    image: quay.io/invidious/invidious-companion:latest\n"
        "    container_name: invidious-companion\n    restart: unless-stopped\n",
        "  invidious-companion:\n    image: quay.io/invidious/invidious-companion:latest\n"
        "    container_name: invidious-companion\n    restart: unless-stopped\n"
        f"    network_mode: container:{container}\n",
    )
    replace_once(
        "    networks:\n      - caleope-internal\n\n  invidious-db:\n",
        "\n  invidious-db:\n",
    )
    replace_once(
        "  caleope-internal:\n    external: true\n",
        f"  caleope-internal:\n    external: true\n  {network}:\n    external: true\n",
    )
    return compose


if __name__ == "__main__":
    try:
        path = Path(sys.argv[1])
        path.write_text(configure(path.read_text(), sys.argv[2], sys.argv[3]))
        print(f"✓ Companion utilise le réseau VPN {sys.argv[3]}")
    except (OSError, IndexError, ValueError) as error:
        print(f"✗ Configuration VPN Companion interrompue : {error}", file=sys.stderr)
        sys.exit(1)
