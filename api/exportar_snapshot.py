"""Exporta el estado actual de la base a JSON para el modo demo del dashboard.

    DATABASE_URL=... python exportar_snapshot.py > ../dashboard/snapshot.json
"""
import json
import main

print(json.dumps(main.tablero(), ensure_ascii=False, separators=(",", ":")))
