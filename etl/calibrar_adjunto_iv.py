"""
Calibra el consumo planificado de SOSTÉN con datos públicos reales.

Fuente: Secretaría de Energía, "Datos de fractura de pozos de hidrocarburos
(Adjunto IV)", publicado en datos.gob.ar / datos.energia.gob.ar.
Descargá el CSV y ejecutá:

    python calibrar_adjunto_iv.py fractura.csv --formacion "vaca muerta" \
        --etapas-dia FS-01=9 FS-02=8 --sql calibracion.sql

Qué hace:
  1. Detecta las columnas de etapas, arena y agua (los nombres cambiaron entre
     versiones del dataset; si no las encuentra, lista las disponibles).
  2. Filtra la formación, calcula arena y agua por etapa en cada pozo y
     descarta valores atípicos (regla de Tukey, 1,5 × IQR).
  3. Informa medianas y cuartiles por año.
  4. Opcional: genera un UPDATE de consumo_plan para cada set de fractura
     usando la mediana del último año completo.
"""
from __future__ import annotations

import argparse
import sys
import unicodedata

import pandas as pd


def normalizar(txt: str) -> str:
    txt = unicodedata.normalize("NFKD", str(txt)).encode("ascii", "ignore").decode()
    return txt.strip().lower().replace(" ", "_")


CANDIDATAS = {
    "formacion": ["formacion_productiva", "formacion", "formacion_objetivo"],
    "etapas": ["cantidad_fracturas", "cantidad_etapas", "etapas", "fracturas", "numero_de_etapas"],
    "arena_nac": ["arena_bombeada_nacional_tn", "arena_nacional_tn", "arena_nacional"],
    "arena_imp": ["arena_bombeada_importada_tn", "arena_importada_tn", "arena_importada"],
    "arena_tot": ["arena_total_tn", "arena_bombeada_tn", "arena_tn", "arena_total"],
    "agua": ["agua_inyectada_m3", "agua_total_m3", "agua_m3", "agua_inyectada"],
    "fecha": ["fecha_inicio_fractura", "fecha_fin_fractura", "fecha_data", "fecha"],
    "pozo": ["idpozo", "id_pozo", "sigla", "pozo"],
}


def buscar(cols: list[str], clave: str) -> str | None:
    for c in CANDIDATAS[clave]:
        if c in cols:
            return c
    # coincidencia parcial como último recurso
    for c in cols:
        if any(c.startswith(x) for x in CANDIDATAS[clave]):
            return c
    return None


def sin_atipicos(s: pd.Series) -> pd.Series:
    q1, q3 = s.quantile([0.25, 0.75])
    iqr = q3 - q1
    return s[(s >= q1 - 1.5 * iqr) & (s <= q3 + 1.5 * iqr)]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("csv")
    ap.add_argument("--formacion", default="vaca muerta")
    ap.add_argument("--etapas-dia", nargs="*", default=[], help="FRENTE=etapas, p.ej. FS-01=9")
    ap.add_argument("--sql", help="archivo .sql de salida con los UPDATE de consumo_plan")
    a = ap.parse_args()

    df = pd.read_csv(a.csv, sep=None, engine="python", encoding_errors="replace")
    df.columns = [normalizar(c) for c in df.columns]
    cols = list(df.columns)
    c = {k: buscar(cols, k) for k in CANDIDATAS}

    faltan = [k for k in ("formacion", "etapas", "agua") if not c[k]]
    if faltan or not (c["arena_tot"] or c["arena_nac"] or c["arena_imp"]):
        print("No encontré todas las columnas necesarias:", faltan or ["arena"], file=sys.stderr)
        print("Columnas disponibles:\n  " + "\n  ".join(cols), file=sys.stderr)
        print("Agregá el nombre correcto a CANDIDATAS y volvé a ejecutar.", file=sys.stderr)
        return 1
    print("Columnas usadas:", {k: v for k, v in c.items() if v})

    df = df[df[c["formacion"]].astype(str).map(normalizar).str.contains(normalizar(a.formacion))]
    num = lambda col: pd.to_numeric(df[col], errors="coerce") if col else 0
    arena = num(c["arena_tot"]) if c["arena_tot"] else num(c["arena_nac"]).fillna(0) + num(c["arena_imp"]).fillna(0)
    etapas = num(c["etapas"])
    d = pd.DataFrame({
        "anio": pd.to_datetime(df[c["fecha"]], errors="coerce", format="mixed").dt.year if c["fecha"] else None,
        "arena_t_etapa": arena / etapas,
        "agua_m3_etapa": num(c["agua"]) / etapas,
    }).replace([float("inf")], pd.NA).dropna(subset=["arena_t_etapa", "agua_m3_etapa"])
    d = d[(d.arena_t_etapa > 0) & (d.agua_m3_etapa > 0)]
    if d.empty:
        print(f"No hay pozos con datos válidos para la formación '{a.formacion}'.", file=sys.stderr)
        return 1

    d = d[d.arena_t_etapa.isin(sin_atipicos(d.arena_t_etapa)) & d.agua_m3_etapa.isin(sin_atipicos(d.agua_m3_etapa))]
    resumen = (d.groupby("anio")[["arena_t_etapa", "agua_m3_etapa"]]
                 .describe(percentiles=[.25, .5, .75])
                 .loc[:, (slice(None), ["count", "25%", "50%", "75%"])].round(1))
    print(f"\nPozos de '{a.formacion}' sin atípicos: {len(d)}\n")
    print(resumen.to_string())

    anios = resumen.index.dropna()
    anio_ref = int(anios[-2]) if len(anios) > 1 else int(anios[-1])   # último año completo
    ref = d[d.anio == anio_ref]
    arena_med, agua_med = ref.arena_t_etapa.median(), ref.agua_m3_etapa.median()
    print(f"\nReferencia {anio_ref}: {arena_med:.0f} t de arena y {agua_med:.0f} m³ de agua por etapa (mediana).")

    if a.sql:
        lineas = [f"-- Calibración con Adjunto IV, formación '{a.formacion}', año {anio_ref}, n = {len(ref)} pozos"]
        for par in a.etapas_dia:
            frente, et = par.split("=")
            et = float(et)
            for insumo, v in (("ARENA", arena_med), ("AGUA", agua_med)):
                lineas.append(
                    f"UPDATE consumo_plan SET cantidad_dia = {v * et:.0f}, "
                    f"fuente = 'Adjunto IV {anio_ref}: mediana {v:.0f}/etapa × {et:g} etapas/día' "
                    f"WHERE id_frente = '{frente}' AND id_insumo = '{insumo}';")
        open(a.sql, "w", encoding="utf-8").write("\n".join(lineas) + "\n")
        print(f"UPDATE generados en {a.sql}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
