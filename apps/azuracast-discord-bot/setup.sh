#!/bin/bash
set -euo pipefail

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/${CALEOPE_APP_ID}"
SRC_DIR="${CONFIG_DIR}/src"
mkdir -p "${SRC_DIR}"

# ── Vérifications obligatoires ──────────────────────────────────────────────
MISSING=()
[ -z "${CALEOPE_PARAM_DISCORD_TOKEN:-}"      ] && MISSING+=("DISCORD_TOKEN")
[ -z "${CALEOPE_PARAM_AZURACAST_URL:-}"      ] && MISSING+=("AZURACAST_URL")
[ -z "${CALEOPE_PARAM_AZURACAST_STATION_ID:-}" ] && MISSING+=("AZURACAST_STATION_ID")

if [ ${#MISSING[@]} -gt 0 ]; then
    echo "  ⚠ Paramètres manquants : ${MISSING[*]}"
    echo "  Configure via : caleope configure ${CALEOPE_APP_ID}"
fi

# ── secrets.env ─────────────────────────────────────────────────────────────
cat > "${CONFIG_DIR}/secrets.env" << EOF
DISCORD_TOKEN=${CALEOPE_PARAM_DISCORD_TOKEN:-}
AZURACAST_URL=${CALEOPE_PARAM_AZURACAST_URL:-}
AZURACAST_STATION_ID=${CALEOPE_PARAM_AZURACAST_STATION_ID:-radio}
AZURACAST_API_KEY=${CALEOPE_PARAM_AZURACAST_API_KEY:-}
STREAM_URL=${CALEOPE_PARAM_STREAM_URL:-}
AUTO_CHANNEL_ID=${CALEOPE_PARAM_AUTO_CHANNEL_ID:-}
DEFAULT_VOLUME=${CALEOPE_PARAM_DEFAULT_VOLUME:-100}
EOF
chmod 600 "${CONFIG_DIR}/secrets.env"

# ── requirements.txt ─────────────────────────────────────────────────────────
cat > "${SRC_DIR}/requirements.txt" << 'PYREQ'
discord.py[voice]>=2.4.0
aiohttp>=3.9.0
PyNaCl>=1.5.0
PYREQ

# ── bot.py ───────────────────────────────────────────────────────────────────
cat > "${SRC_DIR}/bot.py" << 'PYEOF'
#!/usr/bin/env python3
"""AzuraCast Radio Bot — diffuse ta radio en continu dans Discord."""

import asyncio
import logging
import os

import aiohttp
import discord
from discord import app_commands
from discord.ext import commands, tasks

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
log = logging.getLogger("radio-bot")

DISCORD_TOKEN       = os.environ["DISCORD_TOKEN"]
AZURACAST_URL       = os.environ["AZURACAST_URL"].rstrip("/")
AZURACAST_STATION_ID = os.environ.get("AZURACAST_STATION_ID", "radio")
AZURACAST_API_KEY   = os.environ.get("AZURACAST_API_KEY", "")
STREAM_URL_ENV      = os.environ.get("STREAM_URL", "").strip()
AUTO_CHANNEL_ID     = int(os.environ.get("AUTO_CHANNEL_ID", "0") or "0")
DEFAULT_VOLUME      = max(0, min(200, int(os.environ.get("DEFAULT_VOLUME", "100") or "100")))


# ── Player ───────────────────────────────────────────────────────────────────

class RadioPlayer:
    def __init__(self):
        self.voice_client: discord.VoiceClient | None = None
        self.volume: float = DEFAULT_VOLUME / 100.0
        self._cached_stream_url: str = STREAM_URL_ENV

    # -- AzuraCast API --------------------------------------------------------

    async def _get(self, path: str) -> dict:
        headers = {"X-API-Key": AZURACAST_API_KEY} if AZURACAST_API_KEY else {}
        url = f"{AZURACAST_URL}{path}"
        try:
            async with aiohttp.ClientSession() as s:
                async with s.get(url, headers=headers, timeout=aiohttp.ClientTimeout(total=8)) as r:
                    return await r.json()
        except Exception as exc:
            log.warning("AzuraCast GET %s → %s", path, exc)
            return {}

    async def _post(self, path: str, json: dict | None = None) -> dict:
        headers = {"X-API-Key": AZURACAST_API_KEY} if AZURACAST_API_KEY else {}
        url = f"{AZURACAST_URL}{path}"
        try:
            async with aiohttp.ClientSession() as s:
                async with s.post(url, headers=headers, json=json or {},
                                  timeout=aiohttp.ClientTimeout(total=8)) as r:
                    return await r.json()
        except Exception as exc:
            log.warning("AzuraCast POST %s → %s", path, exc)
            return {}

    async def fetch_now_playing(self) -> dict:
        return await self._get(f"/api/nowplaying/{AZURACAST_STATION_ID}")

    async def fetch_stream_url(self) -> str:
        if self._cached_stream_url:
            return self._cached_stream_url
        np = await self.fetch_now_playing()
        mounts = np.get("station", {}).get("mounts", [])
        for m in mounts:
            if m.get("is_default") or m.get("url"):
                url = m.get("url", "")
                if url:
                    self._cached_stream_url = url
                    return url
        hls = np.get("station", {}).get("hls_url", "")
        if hls:
            self._cached_stream_url = hls
        return self._cached_stream_url

    async def skip(self) -> bool:
        """Skip la piste actuelle (nécessite une clé API)."""
        if not AZURACAST_API_KEY:
            return False
        result = await self._post(f"/api/station/{AZURACAST_STATION_ID}/backend/skip")
        return bool(result)

    # -- Lecture vocale -------------------------------------------------------

    def _make_source(self, url: str) -> discord.FFmpegOpusAudio:
        return discord.FFmpegOpusAudio(
            url,
            before_options=(
                "-reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5 "
                "-analyzeduration 0 -loglevel warning"
            ),
            options=f"-vn -filter:a volume={self.volume:.3f}",
        )

    async def play(self, channel: discord.VoiceChannel) -> tuple[bool, str]:
        stream_url = await self.fetch_stream_url()
        if not stream_url:
            return False, "URL du stream introuvable. Vérifie AZURACAST_URL et AZURACAST_STATION_ID."

        if self.voice_client and self.voice_client.is_connected():
            if self.voice_client.channel.id != channel.id:
                await self.voice_client.move_to(channel)
        else:
            self.voice_client = await channel.connect()

        if self.voice_client.is_playing():
            self.voice_client.stop()

        source = self._make_source(stream_url)
        self.voice_client.play(source, after=self._after)
        return True, stream_url

    def _after(self, exc: Exception | None):
        if exc:
            log.error("Erreur lecteur : %s", exc)

    async def stop(self):
        if self.voice_client:
            if self.voice_client.is_playing():
                self.voice_client.stop()
            await self.voice_client.disconnect()
            self.voice_client = None

    async def restart_with_volume(self):
        """Relance le stream pour appliquer le nouveau volume."""
        if not (self.voice_client and self.voice_client.is_connected()):
            return
        channel = self.voice_client.channel
        if self.voice_client.is_playing():
            self.voice_client.stop()
        stream_url = await self.fetch_stream_url()
        if stream_url:
            source = self._make_source(stream_url)
            self.voice_client.play(source, after=self._after)

    @property
    def is_playing(self) -> bool:
        return bool(self.voice_client and self.voice_client.is_playing())


# ── Bot ──────────────────────────────────────────────────────────────────────

intents = discord.Intents.default()
intents.voice_states = True
intents.guilds = True

bot = commands.Bot(command_prefix="!", intents=intents)
player = RadioPlayer()


# ── Helpers embed ─────────────────────────────────────────────────────────────

def np_embed(np: dict) -> discord.Embed:
    embed = discord.Embed(color=0x3498DB)
    if not np:
        embed.title = "❓ Aucune info disponible"
        return embed
    song    = np.get("now_playing", {}).get("song", {})
    station = np.get("station", {})
    elapsed = np.get("now_playing", {}).get("elapsed", 0)
    duration = np.get("now_playing", {}).get("duration", 0)
    listeners = np.get("listeners", {}).get("current", 0)

    title  = song.get("title") or "—"
    artist = song.get("artist") or "—"
    album  = song.get("album") or ""
    art    = song.get("art") or ""

    embed.title = f"🎵 {title}"
    embed.description = f"**{artist}**" + (f" — {album}" if album else "")

    def fmt_time(s: int) -> str:
        return f"{s // 60}:{s % 60:02d}"

    if duration:
        embed.add_field(name="Durée", value=f"{fmt_time(elapsed)} / {fmt_time(duration)}", inline=True)
    embed.add_field(name="Auditeurs", value=str(listeners), inline=True)
    if art:
        embed.set_thumbnail(url=art)
    embed.set_footer(text=station.get("name", AZURACAST_STATION_ID))
    return embed


# ── Events ────────────────────────────────────────────────────────────────────

@bot.event
async def on_ready():
    log.info("Connecté : %s (id %s)", bot.user, bot.user.id)
    await bot.tree.sync()
    log.info("Slash commands synchronisées")

    if AUTO_CHANNEL_ID:
        channel = bot.get_channel(AUTO_CHANNEL_ID)
        if isinstance(channel, discord.VoiceChannel):
            ok, info = await player.play(channel)
            if ok:
                log.info("Auto-join #%s → lecture lancée", channel.name)
            else:
                log.warning("Auto-join échoué : %s", info)

    update_presence.start()


@bot.event
async def on_voice_state_update(member: discord.Member, before: discord.VoiceState, after: discord.VoiceState):
    """Repart si le bot est seul dans le salon (tous les humains sont partis)."""
    if not player.voice_client:
        return
    bot_channel = player.voice_client.channel
    if len([m for m in bot_channel.members if not m.bot]) == 0:
        log.info("Salon vide — pause")
        if player.voice_client.is_playing():
            player.voice_client.pause()


@tasks.loop(minutes=1)
async def update_presence():
    np = await player.fetch_now_playing()
    song = np.get("now_playing", {}).get("song", {}) if np else {}
    title  = song.get("title", "")
    artist = song.get("artist", "")
    text = f"{artist} — {title}" if artist and title else (title or artist or "AzuraCast Radio")
    await bot.change_presence(
        activity=discord.Activity(type=discord.ActivityType.listening, name=text[:128])
    )


# ── Slash commands ────────────────────────────────────────────────────────────

radio_group = app_commands.Group(name="radio", description="Commandes du bot radio AzuraCast")


@radio_group.command(name="play", description="Rejoint ton salon vocal et lance la radio")
async def cmd_play(interaction: discord.Interaction):
    if not interaction.user.voice:
        await interaction.response.send_message(
            "❌ Tu dois être dans un salon vocal.", ephemeral=True
        )
        return
    await interaction.response.defer()
    ok, info = await player.play(interaction.user.voice.channel)
    if ok:
        np = await player.fetch_now_playing()
        await interaction.followup.send("▶️ Radio lancée !", embed=np_embed(np))
    else:
        await interaction.followup.send(f"❌ {info}")


@radio_group.command(name="stop", description="Arrête la radio et quitte le salon vocal")
async def cmd_stop(interaction: discord.Interaction):
    await player.stop()
    await interaction.response.send_message("⏹️ Radio arrêtée.")


@radio_group.command(name="volume", description="Règle le volume (0 à 200 %)")
@app_commands.describe(niveau="Volume en % — 100 = normal, 200 = amplifié ×2")
async def cmd_volume(interaction: discord.Interaction, niveau: int):
    niveau = max(0, min(200, niveau))
    player.volume = niveau / 100.0
    await interaction.response.defer()
    await player.restart_with_volume()
    await interaction.followup.send(f"🔊 Volume : **{niveau} %**")


@radio_group.command(name="np", description="Affiche le titre en cours sur la radio")
async def cmd_np(interaction: discord.Interaction):
    await interaction.response.defer()
    np = await player.fetch_now_playing()
    if not np:
        await interaction.followup.send("❌ Impossible de contacter AzuraCast.")
        return
    await interaction.followup.send(embed=np_embed(np))


@radio_group.command(name="skip", description="Passe au titre suivant (clé API requise)")
async def cmd_skip(interaction: discord.Interaction):
    if not AZURACAST_API_KEY:
        await interaction.response.send_message(
            "❌ Clé API AzuraCast non configurée (paramètre AZURACAST_API_KEY).", ephemeral=True
        )
        return
    await interaction.response.defer()
    ok = await player.skip()
    if ok:
        await asyncio.sleep(1.5)
        np = await player.fetch_now_playing()
        await interaction.followup.send("⏭️ Piste suivante !", embed=np_embed(np))
    else:
        await interaction.followup.send("❌ Le skip a échoué. Vérifie les droits de ta clé API.")


@radio_group.command(name="status", description="Affiche le statut du bot radio")
async def cmd_status(interaction: discord.Interaction):
    playing = player.is_playing
    channel_mention = (
        player.voice_client.channel.mention if player.voice_client and player.voice_client.is_connected()
        else "—"
    )
    vol = int(player.volume * 100)
    color = 0x2ECC71 if playing else 0xE74C3C

    embed = discord.Embed(title="📻 Statut Radio Bot", color=color)
    embed.add_field(name="État",    value="▶️ En lecture" if playing else "⏹️ Arrêté", inline=True)
    embed.add_field(name="Salon",   value=channel_mention, inline=True)
    embed.add_field(name="Volume",  value=f"{vol} %", inline=True)
    embed.add_field(name="Station", value=AZURACAST_STATION_ID, inline=True)
    embed.add_field(name="AzuraCast", value=AZURACAST_URL, inline=False)
    await interaction.response.send_message(embed=embed)


@radio_group.command(name="pause", description="Met la lecture en pause sans quitter le salon")
async def cmd_pause(interaction: discord.Interaction):
    if player.voice_client and player.voice_client.is_playing():
        player.voice_client.pause()
        await interaction.response.send_message("⏸️ Mis en pause.")
    else:
        await interaction.response.send_message("❌ Le bot ne lit rien.", ephemeral=True)


@radio_group.command(name="resume", description="Reprend la lecture après une pause")
async def cmd_resume(interaction: discord.Interaction):
    if player.voice_client and player.voice_client.is_paused():
        player.voice_client.resume()
        await interaction.response.send_message("▶️ Reprise de la lecture.")
    else:
        await interaction.response.send_message("❌ Rien n'est en pause.", ephemeral=True)


bot.tree.add_command(radio_group)

bot.run(DISCORD_TOKEN, log_handler=None)
PYEOF

# ── Dockerfile ───────────────────────────────────────────────────────────────
cat > "${SRC_DIR}/Dockerfile" << 'DEOF'
FROM python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /bot
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY bot.py .

CMD ["python", "-u", "bot.py"]
DEOF

# ── Build de l'image Docker ───────────────────────────────────────────────────
echo "  → Build de l'image Docker (peut prendre 1-2 min au premier lancement)..."
docker build -t caleope-azuracast-discord-bot:latest "${SRC_DIR}" \
    --label "caleope.app=${CALEOPE_APP_ID}" \
    --label "caleope.version=1.0.0"
echo "  ✓ Image construite : caleope-azuracast-discord-bot:latest"

# ── post-install.txt ─────────────────────────────────────────────────────────
STATION_ID="${CALEOPE_PARAM_AZURACAST_STATION_ID:-radio}"
AZ_URL="${CALEOPE_PARAM_AZURACAST_URL:-}"

cat > "${CONFIG_DIR}/post-install.txt" << EOF

  ┌──────────────────────────────────────────────────────────────────────┐
  │              AzuraCast Radio Bot — Installé                          │
  ├──────────────────────────────────────────────────────────────────────┤
  │  Station : ${STATION_ID}
  │  AzuraCast : ${AZ_URL}
  │                                                                      │
  │  Commandes Discord :                                                 │
  │    /radio play   → rejoint ton salon et lance la radio               │
  │    /radio stop   → arrête et quitte le salon                         │
  │    /radio volume → règle le volume (0-200%)                          │
  │    /radio np     → titre en cours                                    │
  │    /radio skip   → passe au suivant (clé API requise)                │
  │    /radio status → statut du bot                                     │
  │    /radio pause  → pause sans quitter                                │
  │    /radio resume → reprend après pause                               │
  │                                                                      │
  │  Prérequis Discord :                                                 │
  │    • Mode développeur activé (Paramètres → Apparence)                │
  │    • Permissions bot : Connect + Speak + Use Slash Commands          │
  │    • Intent "Server Members" activé dans le portail développeur      │
  │                                                                      │
  │  Logs :                                                              │
  │    caleope logs azuracast-discord-bot                                │
  └──────────────────────────────────────────────────────────────────────┘
EOF

echo "✓ AzuraCast Radio Bot configuré"
