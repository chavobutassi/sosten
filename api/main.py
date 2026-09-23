"""
SOSTÉN · API
FastAPI + PostgreSQL (local o Supabase).

La lógica de negocio vive en la base (vistas y triggers). La API expone
lecturas y registra novedades; cada escritura es una sola transacción.

Ejecutar:
    export DATABASE_URL="postgresql://usuario:clave@host:5432/sosten"
    uvicorn main:app --reload
Documentación interactiva: http://localhost:8000/docs
"""
from __future__ import annotations

import os
from contextlib import contextmanager
from datetime import date, datetime
from decimal import Decimal
from typing import Literal, Optional

import psycopg
from psycopg.rows import dict_row
from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

DATABASE_URL = os.environ.get("DATABASE_URL")
ORIGENES = [o.strip() for o in os.environ.get("CORS_ORIGINS", "*").split(",")]

app = FastAPI(
    title="SOSTÉN API",
    description="Monitor de sostenimiento de operaciones de campo",
    version="1.0.0",
)
app.add_middleware(CORSMiddleware, allow_origins=ORIGENES,
                   allow_methods=["GET", "POST", "PATCH"], allow_headers=["*"])


# ---------------------------------------------------------------------
# Conexión
# ---------------------------------------------------------------------
@contextmanager
def conexion():
    if not DATABASE_URL:
        raise HTTPException(500, "Falta la variable de entorno DATABASE_URL")
    try:
        with psycopg.connect(DATABASE_URL, row_factory=dict_row) as conn:
            yield conn          # commit al salir; rollback si hay excepción
    except psycopg.OperationalError as e:
        raise HTTPException(503, f"No se pudo conectar a la base: {e}") from e


def a_json(filas: list[dict]) -> list[dict]:
    """Decimal → float y fechas → ISO, para respuestas JSON limpias."""
    def conv(v):
        if isinstance(v, Decimal):
            return float(v)
        if isinstance(v, (date, datetime)):
            return v.isoformat()
        return v
    return [{k: conv(v) for k, v in f.items()} for f in filas]


def consultar(sql: str, params: tuple = ()) -> list[dict]:
    with conexion() as conn:
        return a_json(conn.execute(sql, params).fetchall())


# Vistas que forman el "tablero". El dashboard usa estas mismas claves.
VISTAS_TABLERO = {
    "frentes": "SELECT * FROM frentes ORDER BY id_frente",
    "v_autonomia": "SELECT * FROM v_autonomia ORDER BY dias_autonomia NULLS LAST",
    "v_indice_sostenimiento": "SELECT * FROM v_indice_sostenimiento ORDER BY dias_autonomia_min NULLS LAST",
    "v_balance_reposicion": "SELECT * FROM v_balance_reposicion ORDER BY cobertura_pct",
    "v_disponibilidad_flota": "SELECT * FROM v_disponibilidad_flota ORDER BY id_frente, tipo",
    "v_rutas_estado": "SELECT * FROM v_rutas_estado ORDER BY id_ruta",
    "v_viajes_kpi": "SELECT * FROM v_viajes_kpi ORDER BY id_ruta",
    "v_alertas_activas": "SELECT * FROM v_alertas_activas",
    "v_acciones_sugeridas": "SELECT * FROM v_acciones_sugeridas ORDER BY urgencia NULLS LAST",
    "v_consumo_diario": "SELECT * FROM v_consumo_diario WHERE fecha >= current_date - 14 ORDER BY fecha",
    "flota": "SELECT id_equipo, id_frente, tipo, id_insumo, capacidad, viajes_dia_max, estado FROM flota ORDER BY id_equipo",
    "v_viajes_recientes": "SELECT * FROM v_viajes_recientes",
}


# ---------------------------------------------------------------------
# Lecturas
# ---------------------------------------------------------------------
@app.get("/api/salud", tags=["Sistema"])
def salud():
    fila = consultar("SELECT now() AS hora_servidor, current_date AS fecha")[0]
    return {"estado": "ok", **fila}


@app.get("/api/tablero", tags=["Tablero"])
def tablero():
    """Todo lo que necesita el dashboard en una sola consulta."""
    with conexion() as conn:
        datos = {k: a_json(conn.execute(sql).fetchall()) for k, sql in VISTAS_TABLERO.items()}
        datos["generado_en"] = conn.execute("SELECT now()::text AS t").fetchone()["t"]
    return datos


@app.get("/api/frentes", tags=["Tablero"])
def frentes():
    return consultar(VISTAS_TABLERO["v_indice_sostenimiento"])


@app.get("/api/autonomia", tags=["Tablero"])
def autonomia(frente: Optional[str] = Query(None, description="id_frente, p.ej. FS-01")):
    if frente:
        return consultar("SELECT * FROM v_autonomia WHERE id_frente = %s ORDER BY dias_autonomia NULLS LAST", (frente,))
    return consultar(VISTAS_TABLERO["v_autonomia"])


@app.get("/api/reposicion", tags=["Tablero"])
def reposicion():
    return consultar(VISTAS_TABLERO["v_balance_reposicion"])


@app.get("/api/flota", tags=["Tablero"])
def flota(frente: Optional[str] = None):
    if frente:
        return consultar("SELECT * FROM v_disponibilidad_flota WHERE id_frente = %s", (frente,))
    return consultar(VISTAS_TABLERO["v_disponibilidad_flota"])


@app.get("/api/rutas", tags=["Tablero"])
def rutas():
    return consultar(VISTAS_TABLERO["v_rutas_estado"])


@app.get("/api/alertas", tags=["Tablero"])
def alertas():
    return consultar(VISTAS_TABLERO["v_alertas_activas"])


@app.get("/api/acciones", tags=["Tablero"])
def acciones():
    return consultar(VISTAS_TABLERO["v_acciones_sugeridas"])


# ---------------------------------------------------------------------
# Escrituras
# ---------------------------------------------------------------------
class ParteConsumo(BaseModel):
    id_frente: str = Field(examples=["FS-01"])
    id_insumo: str = Field(examples=["GASOIL"])
    cantidad: float = Field(gt=0, examples=[12.5])
    fecha: Optional[date] = None
    etapas: Optional[float] = Field(None, ge=0)
    actividad: Optional[str] = None
    reportado_por: Optional[str] = None


@app.post("/api/consumos", status_code=201, tags=["Novedades"])
def registrar_consumo(p: ParteConsumo):
    """Registra un parte. El trigger descuenta stock en la misma transacción
    y lo rechaza si no hay stock suficiente."""
    try:
        with conexion() as conn:
            fila = conn.execute(
                """INSERT INTO consumos (id_frente, id_insumo, fecha, cantidad, etapas, actividad, reportado_por)
                   VALUES (%s, %s, COALESCE(%s, current_date), %s, %s, %s, %s)
                   RETURNING id_consumo""",
                (p.id_frente, p.id_insumo, p.fecha, p.cantidad, p.etapas, p.actividad, p.reportado_por),
            ).fetchone()
            stock = conn.execute(
                "SELECT * FROM v_autonomia WHERE id_frente = %s AND id_insumo = %s",
                (p.id_frente, p.id_insumo),
            ).fetchone()
        return {"id_consumo": fila["id_consumo"], "autonomia": a_json([stock])[0] if stock else None}
    except psycopg.errors.RaiseException as e:
        raise HTTPException(422, e.diag.message_primary) from e
    except psycopg.errors.ForeignKeyViolation as e:
        raise HTTPException(404, "Frente o insumo inexistente") from e


class CambioEstado(BaseModel):
    estado: str


ESTADOS = {
    "flota": ("id_equipo", {"Operativo", "Mantenimiento preventivo", "Mantenimiento correctivo", "Fuera de servicio"}),
    "rutas": ("id_ruta", {"Habilitada", "Restringida", "Cerrada"}),
    "viajes": ("id_viaje", {"Programado", "En tránsito", "Entregado", "Demorado", "Cancelado"}),
    "alertas": ("id_alerta", {"Activa", "Reconocida", "Resuelta"}),
}


def cambiar_estado(tabla: Literal["flota", "rutas", "viajes", "alertas"], id_: str, estado: str):
    pk, validos = ESTADOS[tabla]
    if estado not in validos:
        raise HTTPException(422, f"Estado inválido. Opciones: {sorted(validos)}")
    extra = ", resuelta_en = now()" if tabla == "alertas" and estado == "Resuelta" else ""
    with conexion() as conn:
        fila = conn.execute(
            f"UPDATE {tabla} SET estado = %s{extra} WHERE {pk}::text = %s RETURNING *", (estado, id_)
        ).fetchone()
    if not fila:
        raise HTTPException(404, f"No existe {pk} = {id_}")
    return a_json([fila])[0]


@app.patch("/api/flota/{id_equipo}", tags=["Novedades"])
def estado_equipo(id_equipo: str, c: CambioEstado):
    """Cambia el estado de un equipo. Salir de servicio genera alerta; volver a operativo la resuelve."""
    return cambiar_estado("flota", id_equipo, c.estado)


@app.patch("/api/rutas/{id_ruta}", tags=["Novedades"])
def estado_ruta(id_ruta: str, c: CambioEstado):
    return cambiar_estado("rutas", id_ruta, c.estado)


@app.patch("/api/viajes/{id_viaje}", tags=["Novedades"])
def estado_viaje(id_viaje: int, c: CambioEstado):
    """'En tránsito' descuenta stock en origen; 'Entregado' lo suma en destino."""
    return cambiar_estado("viajes", str(id_viaje), c.estado)


@app.patch("/api/alertas/{id_alerta}", tags=["Novedades"])
def estado_alerta(id_alerta: int, c: CambioEstado):
    return cambiar_estado("alertas", str(id_alerta), c.estado)
