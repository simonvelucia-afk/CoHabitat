#!/usr/bin/env python3
"""Serre IoT — pont MQTT → Supabase.

S'abonne au topic `serre/lectures` et insère chaque lecture dans la table
`serre_lectures`. L'authentification se fait via un compte « appareil »
(email/mot de passe) dont l'adresse se termine par `@device.local` : la RLS
`serre_lectures_insert` réserve l'insertion aux admins et à ces comptes
capteurs. Le jeton est rafraîchi automatiquement.

Note — alternative plus stricte : au lieu d'insérer directement, appeler une
Edge Function Supabase `ingest-lecture` protégée par un secret d'appareil, qui
insère la ligne côté serveur avec le rôle service. Le Pi ne détiendrait alors
qu'un secret étroit. Il suffirait de remplacer `insert_lecture()` par un POST
vers `${SUPABASE_URL}/functions/v1/ingest-lecture`.
"""
import json
import os
import threading
import time

import paho.mqtt.client as mqtt
import requests
from dotenv import load_dotenv

load_dotenv(os.path.join(os.path.dirname(__file__), "config.env"))

MQTT_HOST = os.getenv("MQTT_HOST", "localhost")
MQTT_PORT = int(os.getenv("MQTT_PORT", "1883"))
MQTT_TOPIC = os.getenv("MQTT_TOPIC", "serre/lectures")
MQTT_USERNAME = os.getenv("MQTT_USERNAME") or None
MQTT_PASSWORD = os.getenv("MQTT_PASSWORD") or None

SUPABASE_URL = os.getenv("SUPABASE_URL", "").rstrip("/")
ANON_KEY = os.getenv("SUPABASE_ANON_KEY", "")
DEVICE_EMAIL = os.getenv("DEVICE_EMAIL", "")
DEVICE_PASSWORD = os.getenv("DEVICE_PASSWORD", "")

# Anti-gonflement : n'insérer que sur changement significatif ou battement.
DB_HEARTBEAT = float(os.getenv("DB_HEARTBEAT", "300"))
TEMP_DEADBAND = float(os.getenv("TEMP_DEADBAND", "0.2"))
LEVEL_DEADBAND = float(os.getenv("LEVEL_DEADBAND", "1"))

# Colonnes numériques acceptées de `serre_lectures`.
TEMP_FIELDS = ["temp_air", "reservoir1_temp", "reservoir2_temp", "reservoir3_temp"]
LEVEL_FIELDS = ["reservoir1_pct", "reservoir2_pct", "reservoir3_pct"]
FIELDS = TEMP_FIELDS + LEVEL_FIELDS

_last_written = {}
_last_write_ts = None


def should_write(reading):
    """Décide s'il faut persister : battement écoulé OU variation ≥ seuil."""
    now = time.monotonic()
    if _last_write_ts is None or (now - _last_write_ts) >= DB_HEARTBEAT:
        return True
    for k in TEMP_FIELDS:
        a, b = reading.get(k), _last_written.get(k)
        if a is not None and (b is None or abs(a - b) >= TEMP_DEADBAND):
            return True
    for k in LEVEL_FIELDS:
        a, b = reading.get(k), _last_written.get(k)
        if a is not None and (b is None or abs(a - b) >= LEVEL_DEADBAND):
            return True
    return False

_token_lock = threading.Lock()
_access_token = None
_device_uid = None


def authenticate():
    """Ouvre une session pour le compte appareil ; mémorise jeton et UID."""
    global _access_token, _device_uid
    resp = requests.post(
        f"{SUPABASE_URL}/auth/v1/token?grant_type=password",
        headers={"apikey": ANON_KEY, "Content-Type": "application/json"},
        json={"email": DEVICE_EMAIL, "password": DEVICE_PASSWORD},
        timeout=15,
    )
    resp.raise_for_status()
    body = resp.json()
    with _token_lock:
        _access_token = body["access_token"]
        _device_uid = (body.get("user") or {}).get("id")
    print(f"[bridge] authentifié auprès de Supabase (uid={_device_uid})")


def insert_lecture(reading):
    """Insère une ligne serre_lectures ; ré-authentifie sur 401. Retourne bool."""
    row = {k: reading.get(k) for k in FIELDS if reading.get(k) is not None}
    if not row:
        return False
    if "ts" in reading:
        row["horodatage"] = reading["ts"]
    # Traçabilité de l'auteur de la lecture (l'accès en écriture, lui, est
    # accordé par la RLS au compte capteur @device.local).
    if _device_uid:
        row["created_by"] = _device_uid

    for attempt in (1, 2):
        with _token_lock:
            token = _access_token
        resp = requests.post(
            f"{SUPABASE_URL}/rest/v1/serre_lectures",
            headers={
                "apikey": ANON_KEY,
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
                "Prefer": "return=minimal",
            },
            json=row,
            timeout=15,
        )
        if resp.status_code == 401 and attempt == 1:
            print("[bridge] jeton expiré → ré-authentification")
            authenticate()
            continue
        if resp.ok:
            print(f"[bridge] inséré : {row}")
            return True
        print(f"[bridge] échec insertion {resp.status_code}: {resp.text}")
        return False
    return False


def on_connect(client, userdata, flags, reason_code, properties):
    print(f"[bridge] connecté au broker (rc={reason_code}) — abonnement à '{MQTT_TOPIC}'")
    client.subscribe(MQTT_TOPIC, qos=1)


def on_message(client, userdata, msg):
    global _last_write_ts
    try:
        reading = json.loads(msg.payload.decode("utf-8"))
    except (ValueError, UnicodeDecodeError) as e:
        print(f"[bridge] payload invalide: {e}")
        return
    if not should_write(reading):
        return  # variation sous le seuil et battement non écoulé → on n'écrit pas
    try:
        if insert_lecture(reading):
            for k in FIELDS:
                if reading.get(k) is not None:
                    _last_written[k] = reading[k]
            _last_write_ts = time.monotonic()
    except Exception as e:  # pragma: no cover
        print(f"[bridge] erreur: {e}")


def main():
    if not (SUPABASE_URL and ANON_KEY and DEVICE_EMAIL and DEVICE_PASSWORD):
        raise SystemExit("Config incomplète : renseignez SUPABASE_URL, SUPABASE_ANON_KEY, "
                         "DEVICE_EMAIL, DEVICE_PASSWORD dans config.env")
    authenticate()

    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id="serre-bridge")
    if MQTT_USERNAME:
        client.username_pw_set(MQTT_USERNAME, MQTT_PASSWORD)
    client.on_connect = on_connect
    client.on_message = on_message
    while True:
        try:
            client.connect(MQTT_HOST, MQTT_PORT, keepalive=60)
            client.loop_forever()
        except (ConnectionRefusedError, OSError) as e:
            print(f"[bridge] broker injoignable ({e}) — nouvelle tentative dans 10 s")
            time.sleep(10)


if __name__ == "__main__":
    main()
