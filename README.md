# SOSTÉN · Monitor de sostenimiento de operaciones de campo

> **EN:** A decision-support system for supplying remote field operations (hydraulic fracturing spreads, drilling rigs, camps). It computes days of supply per site and input, fleet replenishment coverage, weather-adjusted route risk, and turns those KPIs into ranked actions. PostgreSQL (views + triggers), FastAPI, and a single-file dashboard with a replenishment simulator. Scenario and operator are fictional; volumes are calibrated with Argentina's public fracturing dataset.

Un set de fractura en Vaca Muerta consume por día miles de toneladas de arena, más de diez mil metros cúbicos de agua y decenas de metros cúbicos de gasoil, a 60–120 km de la base, por caminos de ripio expuestos al viento. Si falta un insumo, se para la operación.

SOSTÉN responde tres preguntas cada mañana:

1. **¿Qué frente se queda sin qué, y cuándo?** Días de cobertura por frente e insumo, al ritmo de consumo real.
2. **¿La flota alcanza a reponer?** Capacidad diaria de los equipos operativos contra el consumo, considerando equipos fuera de servicio y la ruta en uso.
3. **¿Qué hago ahora?** Acciones priorizadas: despachos urgentes, desvíos de ruta, refuerzo de flota, desvíos de consumo contra el plan.

**Demo:** abrí `dashboard/sosten_demo.html` en el navegador. Funciona sin servidor con el escenario incluido. `dashboard/sosten.html` es la misma aplicación sin datos embebidos, para conectarla a tu API o a Supabase.

---

## Arquitectura

```mermaid
flowchart LR
  A[Partes diarios<br/>de consumo] --> DB
  B[Estado de flota<br/>y mantenimiento] --> DB
  C[Viajes y rutas] --> DB
  E[Clima por zona] --> DB
  F[Adjunto IV<br/>Secretaría de Energía] -- calibración --> P[consumo_plan]
  P --> DB[(PostgreSQL / Supabase<br/>tablas + triggers)]
  DB --> V[Vistas de KPIs]
  V --> API[FastAPI]
  V -- REST de Supabase --> UI
  API --> UI[Dashboard + simulador]
```

La lógica de negocio vive en la base: cualquier cliente (el dashboard, Power BI, una planilla) lee las mismas vistas y obtiene los mismos números.

## Modelo de datos

| Tabla | Qué guarda |
|---|---|
| `frentes` | Base logística, sets de fractura, equipos de perforación, campamentos |
| `insumos` | Arena, agua, gasoil, químicos, viandas, agua potable |
| `stock` | Nivel actual y umbrales (crítico, mínimo, objetivo) por frente e insumo |
| `consumo_plan` | Línea base del programa de trabajo |
| `consumos` | Partes diarios reales |
| `flota` | Equipos, qué transportan, capacidad, ciclos por día, estado |
| `rutas` | Distancia, superficie, tiempo, riesgo base, zona climática, principal o variante |
| `clima` | Viento y lluvia por zona y día |
| `viajes` | Despachos con salida, llegada planificada y real |
| `mantenimiento` | Preventivos y correctivos, repuestos pendientes |
| `alertas` | Generadas por triggers o cargadas a mano |

### Reglas automáticas (triggers)

- Un parte de consumo descuenta stock **en la misma transacción** y se rechaza si deja el stock en negativo.
- Un viaje que sale descuenta en origen; al entregarse suma en destino.
- Cruzar el umbral mínimo o crítico genera una alerta; reponer por encima del mínimo la resuelve.
- Un equipo fuera de servicio o una ruta cerrada generan alerta; al normalizarse, se resuelve.

### Vistas (KPIs)

| Vista | Indicador |
|---|---|
| `v_autonomia` | Días de cobertura (consumo real y plan), desvío contra plan, fecha de quiebre, semáforo |
| `v_balance_reposicion` | Capacidad diaria de la flota operativa ÷ consumo diario |
| `v_indice_sostenimiento` | Índice 0–1 por frente e insumo limitante |
| `v_disponibilidad_flota` | Operativos / mantenimiento / fuera de servicio por tipo de equipo |
| `v_rutas_estado` | Riesgo efectivo = riesgo base + viento + lluvia sobre ripio o tierra |
| `v_viajes_kpi` | Entregas a tiempo, demora media, cancelaciones por ruta |
| `v_acciones_sugeridas` | Reglas que convierten los KPIs en acciones, ordenadas por urgencia |

**Cómo se calcula la autonomía.** Los partes de un mismo día se suman primero y después se promedia sobre los días operados de la última semana cerrada. Promediar partes sueltos subestima el consumo cuando hay varios por día.

## Cómo ejecutarlo

### Base de datos

PostgreSQL 14+ local:

```bash
createdb sosten
psql -d sosten -f db/01_schema.sql -f db/02_logica.sql -f db/03_seed_escenario.sql
```

Supabase: pegar en el SQL Editor, en orden, `01_schema.sql`, `02_logica.sql`, `03_seed_escenario.sql` y `04_supabase.sql` (este último activa RLS: lectura con la clave anon, escritura solo autenticados).

El escenario usa fechas relativas a `current_date`, así que la demo siempre muestra "hoy". Para volver al estado inicial, ejecutá de nuevo `03_seed_escenario.sql`.

### API

```bash
cd api
pip install -r requirements.txt
export DATABASE_URL="postgresql://usuario:clave@localhost:5432/sosten"
uvicorn main:app --reload
```

Documentación interactiva en `http://localhost:8000/docs`. Endpoints principales: `GET /api/tablero` (todo el tablero en una llamada), `POST /api/consumos`, `PATCH /api/flota/{id}`, `PATCH /api/viajes/{id}`, `PATCH /api/rutas/{id}`.

### Dashboard

`dashboard/sosten.html` es un único archivo. Por defecto usa el escenario incluido; desde **Fuente de datos** se conecta a la API o directamente a Supabase.

Para regenerar la demo desde la base:

```bash
cd api && python exportar_snapshot.py > ../dashboard/snapshot.json
cd ../dashboard && python build.py snapshot.json sosten.html sosten_demo.html
```

El simulador proyecta el stock a 5 días con la flota trabajando. Permite cambiar etapas de fractura por día, camiones areneros operativos, ruta (principal o variante; la variante reduce los ciclos por día en proporción al tiempo de tránsito) y un despacho urgente de gasoil.

## Datos

La operadora, los bloques, la flota y los niveles de stock son **ficticios**. Los consumos del escenario usan órdenes de magnitud de una fractura no convencional: unas 250 t de arena y 1.200 m³ de agua por etapa, 8–9 etapas por día.

`etl/calibrar_adjunto_iv.py` reemplaza esos supuestos por medianas reales del dataset público **Datos de fractura de pozos de hidrocarburos (Adjunto IV)** de la Secretaría de Energía:

```bash
python etl/calibrar_adjunto_iv.py fractura.csv --formacion "vaca muerta" \
    --etapas-dia FS-01=9 FS-02=8 --sql calibracion.sql
psql -d sosten -f calibracion.sql
```

El script detecta las columnas de etapas, arena y agua, descarta atípicos (regla de Tukey) y resume por año. Los nombres de columna cambiaron entre versiones del dataset: si no los encuentra, lista los disponibles para agregarlos.

## Próximos pasos

- Pronóstico de consumo por etapa (regresión sobre arena por etapa según longitud de rama y año).
- Clima automático desde una API meteorológica por zona.
- Mapa con geometría real de caminos (PostGIS).
- Carga de partes desde el celular, con cola offline.

## Autor

Claudio J. Butassi, Data Analyst · [github.com/chavobutassi](https://github.com/chavobutassi) · [portfolio](https://cjbutassi-datar.vercel.app)
