#!/usr/bin/env python3
"""Serre IoT — lecture des capteurs et publication MQTT.

Lit la température de l'air et, pour chaque réservoir, sa température (DS18B20)
et son niveau (HC-SR04), puis publie un message JSON combiné sur le topic MQTT
`serre/lectures` toutes les PUBLISH_INTERVAL secondes.

Toute lecture qui échoue est publiée comme `null` (le pont l'ignorera), afin
qu'une panne de capteur n'interrompe pas les autres.
"""
import json
import os
import time
from datetime import datetime, timezone

import paho.mqtt.client as mqtt
from dotenv import load_dotenv

load_dotenv(os.path.join(os.path.dirname(__file__), "config.env"))

MQTT_HOST = os.getenv("MQTT_HOST", "localhost")
MQTT_PORT = int(os.getenv("MQTT_PORT", "1883"))
MQTT_TOPIC = os.getenv("MQTT_TOPIC", "serre/lectures")
MQTT_USERNAME = os.getenv("MQTT_USERNAME") or None
MQTT_PASSWORD = os.getenv("MQTT_PASSWORD") or None
PUBLISH_INTERVAL = int(os.getenv("PUBLISH_INTERVAL", "300"))

W1_DEVICES_PATH = "/sys/bus/w1/devices"


# ── DS18B20 (1-Wire) ────────────────────────────────────────────────────────
def read_ds18b20(rom_id):
    """Retourne la température (°C) d'une sonde DS18B20, ou None si indisponible."""
    if not rom_id:
        return None
    path = os.path.join(W1_DEVICES_PATH, rom_id, "w1_slave")
    try:
        with open(path, "r") as f:
            data = f.read()
        if "YES" not in data.split("\n")[0]:  # CRC invalide
            return None
        raw = data.split("t=")[-1].strip()
        return round(int(raw) / 1000.0, 2)
    except (FileNotFoundError, ValueError, IndexError):
        return None


# ── Niveau : capteur de pression hydrostatique via ADC I2C ADS1115 ──────────
# La pression au fond du réservoir est proportionnelle à la hauteur d'eau ;
# le capteur (0,5-4,5 V ratiométrique, ou 4-20 mA avec résistance shunt) sort
# une tension lue par l'ADS1115. On interpole entre V_EMPTY (réservoir vide) et
# V_FULL (réservoir plein). Import paresseux → testable hors Pi.
_ads = None


def _get_ads():
    global _ads
    if _ads is None:
        import board
        import busio
        from adafruit_ads1x15.ads1115 import ADS1115
        i2c = busio.I2C(board.SCL, board.SDA)
        _ads = ADS1115(i2c, address=int(os.getenv("ADC_ADDRESS", "0x48"), 16))
        # Gain : 2/3 (±6,144 V) couvre les capteurs 0,5-4,5 V sans écrêtage.
        g = os.getenv("ADC_GAIN", "2/3")
        _ads.gain = (2 / 3) if g in ("2/3", "0.6667", "0.667") else float(g)
    return _ads


def read_level_pct(chan_env, v_empty, v_full):
    """Lit la tension du capteur de pression et l'interpole en % (0-100)."""
    chan = os.getenv(chan_env)
    if chan in (None, ""):
        return None
    try:
        from adafruit_ads1x15.analog_in import AnalogIn
        ain = AnalogIn(_get_ads(), int(chan))
        volts = sorted(ain.voltage for _ in range(5))[2]  # médiane de 5 mesures
        span = float(v_full) - float(v_empty)
        if span == 0:
            return None
        pct = (volts - float(v_empty)) / span * 100.0
        pct = round(max(0.0, min(100.0, pct)))
        # Tension brute affichée pour aider à la calibration (V_EMPTY / V_FULL).
        print(f"[niveau] {chan_env}: {volts:.3f} V -> {pct} %")
        return pct
    except Exception as e:  # pragma: no cover - dépend du matériel
        print(f"[niveau] erreur lecture ({chan_env}): {e}")
        return None


def read_all():
    """Construit une lecture complète (dict) à partir de tous les capteurs."""
    reading = {
        "temp_air": read_ds18b20(os.getenv("W1_AIR")),
        "ts": datetime.now(timezone.utc).isoformat(),
    }
    for n in (1, 2, 3):
        reading[f"reservoir{n}_temp"] = read_ds18b20(os.getenv(f"W1_RESERVOIR{n}"))
        reading[f"reservoir{n}_pct"] = read_level_pct(
            f"RES{n}_ADC_CHAN",
            os.getenv(f"RES{n}_V_EMPTY", "0.5"),
            os.getenv(f"RES{n}_V_FULL", "4.5"),
        )
    return reading


def main():
    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id="serre-sensors")
    if MQTT_USERNAME:
        client.username_pw_set(MQTT_USERNAME, MQTT_PASSWORD)
    client.connect(MQTT_HOST, MQTT_PORT, keepalive=60)
    client.loop_start()
    print(f"[serre-sensors] publication sur {MQTT_HOST}:{MQTT_PORT} topic '{MQTT_TOPIC}' "
          f"toutes les {PUBLISH_INTERVAL}s")
    try:
        while True:
            reading = read_all()
            client.publish(MQTT_TOPIC, json.dumps(reading), qos=1, retain=True)
            print(f"[serre-sensors] {reading}")
            time.sleep(PUBLISH_INTERVAL)
    except KeyboardInterrupt:
        pass
    finally:
        client.loop_stop()
        client.disconnect()


if __name__ == "__main__":
    main()
