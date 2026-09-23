-- =====================================================================
-- SOSTÉN · Monitor de sostenimiento de operaciones de campo
-- Esquema PostgreSQL 14+ (compatible con Supabase)
-- Autor: Claudio J. Butassi · github.com/chavobutassi
--
-- Modela el abastecimiento de frentes remotos de trabajo (sets de
-- fractura, equipos de perforación, campamentos) desde una base
-- logística: stock, consumos, flota, rutas, viajes, clima y alertas.
-- =====================================================================

DROP TABLE IF EXISTS alertas, mantenimiento, viajes, clima, rutas, flota,
                     consumos, consumo_plan, stock, insumos, frentes CASCADE;

-- ---------------------------------------------------------------------
-- 1. FRENTES DE TRABAJO (nodo central)
-- ---------------------------------------------------------------------
CREATE TABLE frentes (
    id_frente        TEXT PRIMARY KEY,
    nombre           TEXT NOT NULL,
    tipo             TEXT NOT NULL CHECK (tipo IN
                       ('Base logística','Set de fractura','Equipo de perforación','Campamento')),
    bloque           TEXT,
    lat              NUMERIC(9,6),
    lon              NUMERIC(9,6),
    dotacion         INT  NOT NULL DEFAULT 0 CHECK (dotacion >= 0),
    etapas_plan_dia  NUMERIC(5,1),              -- solo sets de fractura
    base_apoyo       TEXT REFERENCES frentes(id_frente),
    estado           TEXT NOT NULL DEFAULT 'Activo'
                       CHECK (estado IN ('Activo','En espera','Desmovilizado')),
    actualizado_en   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- 2. CATÁLOGO DE INSUMOS
-- ---------------------------------------------------------------------
CREATE TABLE insumos (
    id_insumo      TEXT PRIMARY KEY,
    nombre         TEXT NOT NULL,
    categoria      TEXT NOT NULL CHECK (categoria IN
                     ('Agente de sostén','Agua','Combustible','Químicos','Campamento')),
    unidad         TEXT NOT NULL,              -- t, m3, raciones
    critico        BOOLEAN NOT NULL DEFAULT false  -- detiene la operación si falta
);

-- ---------------------------------------------------------------------
-- 3. STOCK POR FRENTE E INSUMO
-- ---------------------------------------------------------------------
CREATE TABLE stock (
    id_frente        TEXT NOT NULL REFERENCES frentes(id_frente) ON DELETE CASCADE,
    id_insumo        TEXT NOT NULL REFERENCES insumos(id_insumo),
    cantidad_actual  NUMERIC(12,2) NOT NULL CHECK (cantidad_actual >= 0),
    umbral_critico   NUMERIC(12,2) NOT NULL,
    stock_minimo     NUMERIC(12,2) NOT NULL,
    stock_objetivo   NUMERIC(12,2) NOT NULL CHECK (stock_objetivo > 0),
    actualizado_en   TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (id_frente, id_insumo),
    CHECK (umbral_critico <= stock_minimo AND stock_minimo <= stock_objetivo)
);

-- ---------------------------------------------------------------------
-- 4. CONSUMO PLANIFICADO (línea base del programa)
-- ---------------------------------------------------------------------
CREATE TABLE consumo_plan (
    id_frente      TEXT NOT NULL REFERENCES frentes(id_frente) ON DELETE CASCADE,
    id_insumo      TEXT NOT NULL REFERENCES insumos(id_insumo),
    cantidad_dia   NUMERIC(12,2) NOT NULL CHECK (cantidad_dia >= 0),
    fuente         TEXT,                        -- p.ej. 'Programa de fractura rev. 3'
    PRIMARY KEY (id_frente, id_insumo)
);

-- ---------------------------------------------------------------------
-- 5. CONSUMOS REALES (partes diarios)
-- ---------------------------------------------------------------------
CREATE TABLE consumos (
    id_consumo     BIGSERIAL PRIMARY KEY,
    id_frente      TEXT NOT NULL REFERENCES frentes(id_frente) ON DELETE CASCADE,
    id_insumo      TEXT NOT NULL REFERENCES insumos(id_insumo),
    fecha          DATE NOT NULL DEFAULT current_date,
    cantidad       NUMERIC(12,2) NOT NULL CHECK (cantidad > 0),
    etapas         NUMERIC(5,1),                -- etapas de fractura del parte
    actividad      TEXT,
    reportado_por  TEXT,
    creado_en      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_consumos_frente_fecha ON consumos (id_frente, id_insumo, fecha);

-- ---------------------------------------------------------------------
-- 6. FLOTA Y EQUIPOS
-- ---------------------------------------------------------------------
CREATE TABLE flota (
    id_equipo       TEXT PRIMARY KEY,
    id_frente       TEXT NOT NULL REFERENCES frentes(id_frente),
    tipo            TEXT NOT NULL,              -- Camión arenero, Cisterna gasoil, ...
    id_insumo       TEXT REFERENCES insumos(id_insumo),   -- qué transporta (si aplica)
    capacidad       NUMERIC(10,2),              -- en la unidad del insumo
    viajes_dia_max  NUMERIC(4,1),               -- ciclos posibles por día
    estado          TEXT NOT NULL DEFAULT 'Operativo' CHECK (estado IN
                      ('Operativo','Mantenimiento preventivo','Mantenimiento correctivo','Fuera de servicio')),
    horas_uso       NUMERIC(10,1) DEFAULT 0,
    ultimo_mant     DATE,
    actualizado_en  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_flota_estado ON flota (estado);

-- ---------------------------------------------------------------------
-- 7. RUTAS
-- ---------------------------------------------------------------------
CREATE TABLE rutas (
    id_ruta        TEXT PRIMARY KEY,
    origen         TEXT NOT NULL REFERENCES frentes(id_frente),
    destino        TEXT NOT NULL REFERENCES frentes(id_frente),
    nombre         TEXT NOT NULL,
    distancia_km   NUMERIC(7,1) NOT NULL CHECK (distancia_km > 0),
    superficie     TEXT NOT NULL CHECK (superficie IN ('Asfalto','Ripio','Tierra','Mixta')),
    tiempo_min     INT NOT NULL,                -- tiempo de tránsito cargado, sin demoras
    riesgo_base    SMALLINT NOT NULL CHECK (riesgo_base BETWEEN 1 AND 5),
    es_principal   BOOLEAN NOT NULL DEFAULT true,
    zona_clima     TEXT NOT NULL,
    estado         TEXT NOT NULL DEFAULT 'Habilitada'
                     CHECK (estado IN ('Habilitada','Restringida','Cerrada'))
);

-- ---------------------------------------------------------------------
-- 8. CLIMA POR ZONA (pronóstico / observado)
-- ---------------------------------------------------------------------
CREATE TABLE clima (
    zona           TEXT NOT NULL,
    fecha          DATE NOT NULL,
    viento_kmh     NUMERIC(5,1) NOT NULL,       -- ráfaga máxima
    lluvia_mm      NUMERIC(5,1) NOT NULL DEFAULT 0,
    temp_min_c     NUMERIC(4,1),
    PRIMARY KEY (zona, fecha)
);

-- ---------------------------------------------------------------------
-- 9. VIAJES DE ABASTECIMIENTO
-- ---------------------------------------------------------------------
CREATE TABLE viajes (
    id_viaje        BIGSERIAL PRIMARY KEY,
    id_ruta         TEXT NOT NULL REFERENCES rutas(id_ruta),
    id_equipo       TEXT NOT NULL REFERENCES flota(id_equipo),
    id_insumo       TEXT NOT NULL REFERENCES insumos(id_insumo),
    cantidad        NUMERIC(10,2) NOT NULL CHECK (cantidad > 0),
    salida          TIMESTAMPTZ NOT NULL,
    llegada_plan    TIMESTAMPTZ NOT NULL,
    llegada_real    TIMESTAMPTZ,
    estado          TEXT NOT NULL DEFAULT 'Programado' CHECK (estado IN
                      ('Programado','En tránsito','Entregado','Demorado','Cancelado')),
    CHECK (llegada_plan > salida)
);
CREATE INDEX idx_viajes_estado ON viajes (estado, salida);

-- ---------------------------------------------------------------------
-- 10. MANTENIMIENTO
-- ---------------------------------------------------------------------
CREATE TABLE mantenimiento (
    id_mant        BIGSERIAL PRIMARY KEY,
    id_equipo      TEXT NOT NULL REFERENCES flota(id_equipo) ON DELETE CASCADE,
    tipo           TEXT NOT NULL CHECK (tipo IN ('Preventivo','Correctivo')),
    inicio         TIMESTAMPTZ NOT NULL,
    fin            TIMESTAMPTZ,
    descripcion    TEXT,
    repuesto_pendiente BOOLEAN NOT NULL DEFAULT false
);

-- ---------------------------------------------------------------------
-- 11. ALERTAS (generadas por triggers o manualmente)
-- ---------------------------------------------------------------------
CREATE TABLE alertas (
    id_alerta      BIGSERIAL PRIMARY KEY,
    id_frente      TEXT REFERENCES frentes(id_frente) ON DELETE CASCADE,
    tipo           TEXT NOT NULL,               -- Stock crítico, Equipo fuera de servicio, Ruta, ...
    severidad      TEXT NOT NULL CHECK (severidad IN ('Crítica','Alta','Media','Baja')),
    descripcion    TEXT NOT NULL,
    id_insumo      TEXT REFERENCES insumos(id_insumo),
    id_equipo      TEXT REFERENCES flota(id_equipo),
    id_ruta        TEXT REFERENCES rutas(id_ruta),
    valor_actual   NUMERIC(12,2),
    umbral         NUMERIC(12,2),
    estado         TEXT NOT NULL DEFAULT 'Activa'
                     CHECK (estado IN ('Activa','Reconocida','Resuelta')),
    creada_en      TIMESTAMPTZ NOT NULL DEFAULT now(),
    resuelta_en    TIMESTAMPTZ
);
CREATE INDEX idx_alertas_estado ON alertas (estado, severidad);
