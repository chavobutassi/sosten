"""Inserta el snapshot en el HTML para que la demo funcione sin servidor.

    python build.py snapshot.json sosten.html salida.html
"""
import json, sys

snap = json.load(open(sys.argv[1], encoding="utf-8"))
v = snap["v_viajes_recientes"]
snap["v_viajes_recientes"] = [x for x in v if x["estado"] != "Entregado"] + [x for x in v if x["estado"] == "Entregado"][:20]
html = open(sys.argv[2], encoding="utf-8").read()
marca = "/*__SNAPSHOT__*/null"
assert marca in html, "No se encontró el marcador del snapshot"
html = html.replace(marca, json.dumps(snap, ensure_ascii=False, separators=(",", ":")))
open(sys.argv[3], "w", encoding="utf-8").write(html)
print(f"OK: {sys.argv[3]} ({len(html)//1024} KB)")
