-- =====================================================================
-- SOSTÉN · Lógica: triggers (reglas automáticas) y vistas (KPIs)
-- =====================================================================

-- =====================================================================
-- A. TRIGGERS
-- =====================================================================

-- A1. Cada consumo informado descuenta stock en la misma transacción.
--     Si no existe el stock o quedaría negativo, el parte se rechaza.
CREATE OR REPLACE FUNCTION fn_consumo_descuenta_stock() RETURNS trigger AS $$
DECLARE v_restante NUMERIC;
BEGIN
    UPDATE stock
       SET cantidad_actual = cantidad_actual - NEW.cantidad,
           actualizado_en  = now()
     WHERE id_frente = NEW.id_frente AND id_insumo = NEW.id_insumo
    RETURNING cantidad_actual INTO v_restante;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El frente % no tiene stock registrado de %', NEW.id_frente, NEW.id_insumo;
    END IF;
    RETURN NEW;
EXCEPTION WHEN check_violation THEN
    RAISE EXCEPTION 'Consumo de % % supera el stock disponible en %',
        NEW.cantidad, NEW.id_insumo, NEW.id_frente;
END $$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_consumo_descuenta_stock ON consumos;
CREATE TRIGGER trg_consumo_descuenta_stock
AFTER INSERT ON consumos
FOR EACH ROW EXECUTE FUNCTION fn_consumo_descuenta_stock();


-- A2. Viajes: al salir descuenta en origen, al entregar suma en destino.
CREATE OR REPLACE FUNCTION fn_viaje_mueve_stock() RETURNS trigger AS $$
DECLARE r rutas%ROWTYPE;
BEGIN
    SELECT * INTO r FROM rutas WHERE id_ruta = NEW.id_ruta;

    IF NEW.estado = 'En tránsito' AND OLD.estado = 'Programado' THEN
        UPDATE stock SET cantidad_actual = cantidad_actual - NEW.cantidad, actualizado_en = now()
         WHERE id_frente = r.origen AND id_insumo = NEW.id_insumo;
    END IF;

    IF NEW.estado = 'Entregado' AND OLD.estado <> 'Entregado' THEN
        UPDATE stock SET cantidad_actual = cantidad_actual + NEW.cantidad, actualizado_en = now()
         WHERE id_frente = r.destino AND id_insumo = NEW.id_insumo;
        IF NEW.llegada_real IS NULL THEN
            UPDATE viajes SET llegada_real = now() WHERE id_viaje = NEW.id_viaje;
        END IF;
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_viaje_mueve_stock ON viajes;
CREATE TRIGGER trg_viaje_mueve_stock
AFTER UPDATE OF estado ON viajes
FOR EACH ROW EXECUTE FUNCTION fn_viaje_mueve_stock();


-- A3. Stock: alerta al cruzar umbrales hacia abajo, cierre automático al reponer.
CREATE OR REPLACE FUNCTION fn_stock_alertas() RETURNS trigger AS $$
BEGIN
    -- Cruce del umbral crítico
    IF NEW.cantidad_actual <= NEW.umbral_critico AND OLD.cantidad_actual > NEW.umbral_critico THEN
        INSERT INTO alertas (id_frente, tipo, severidad, descripcion, id_insumo, valor_actual, umbral)
        SELECT NEW.id_frente, 'Stock crítico', 'Crítica',
               format('%s por debajo del umbral crítico en %s', i.nombre, f.nombre),
               NEW.id_insumo, NEW.cantidad_actual, NEW.umbral_critico
          FROM insumos i, frentes f
         WHERE i.id_insumo = NEW.id_insumo AND f.id_frente = NEW.id_frente;

    -- Cruce del mínimo (sin llegar a crítico)
    ELSIF NEW.cantidad_actual <= NEW.stock_minimo AND OLD.cantidad_actual > NEW.stock_minimo THEN
        INSERT INTO alertas (id_frente, tipo, severidad, descripcion, id_insumo, valor_actual, umbral)
        SELECT NEW.id_frente, 'Stock bajo', 'Alta',
               format('%s por debajo del mínimo en %s', i.nombre, f.nombre),
               NEW.id_insumo, NEW.cantidad_actual, NEW.stock_minimo
          FROM insumos i, frentes f
         WHERE i.id_insumo = NEW.id_insumo AND f.id_frente = NEW.id_frente;
    END IF;

    -- Reposición por encima del mínimo: se resuelven las alertas de ese stock
    IF NEW.cantidad_actual > NEW.stock_minimo AND OLD.cantidad_actual <= NEW.stock_minimo THEN
        UPDATE alertas SET estado = 'Resuelta', resuelta_en = now()
         WHERE id_frente = NEW.id_frente AND id_insumo = NEW.id_insumo
           AND tipo IN ('Stock crítico','Stock bajo') AND estado <> 'Resuelta';
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_stock_alertas ON stock;
CREATE TRIGGER trg_stock_alertas
AFTER UPDATE OF cantidad_actual ON stock
FOR EACH ROW EXECUTE FUNCTION fn_stock_alertas();


-- A4. Flota: alerta cuando un equipo sale de servicio, cierre al volver.
CREATE OR REPLACE FUNCTION fn_flota_alertas() RETURNS trigger AS $$
BEGIN
    IF NEW.estado = 'Fuera de servicio' AND OLD.estado <> 'Fuera de servicio' THEN
        INSERT INTO alertas (id_frente, tipo, severidad, descripcion, id_equipo, id_insumo)
        VALUES (NEW.id_frente, 'Equipo fuera de servicio', 'Alta',
                format('%s %s fuera de servicio', NEW.tipo, NEW.id_equipo),
                NEW.id_equipo, NEW.id_insumo);
    ELSIF NEW.estado = 'Operativo' AND OLD.estado <> 'Operativo' THEN
        UPDATE alertas SET estado = 'Resuelta', resuelta_en = now()
         WHERE id_equipo = NEW.id_equipo AND estado <> 'Resuelta';
    END IF;
    NEW.actualizado_en := now();
    RETURN NEW;
END $$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_flota_alertas ON flota;
CREATE TRIGGER trg_flota_alertas
BEFORE UPDATE OF estado ON flota
FOR EACH ROW EXECUTE FUNCTION fn_flota_alertas();


-- A5. Rutas: alerta al destino cuando se cierra o restringe una ruta.
CREATE OR REPLACE FUNCTION fn_ruta_alertas() RETURNS trigger AS $$
BEGIN
    IF NEW.estado <> 'Habilitada' AND OLD.estado = 'Habilitada' THEN
        INSERT INTO alertas (id_frente, tipo, severidad, descripcion, id_ruta)
        VALUES (NEW.destino, 'Ruta ' || lower(NEW.estado),
                CASE WHEN NEW.estado = 'Cerrada' AND NEW.es_principal THEN 'Crítica' ELSE 'Alta' END,
                format('%s: ruta %s', NEW.nombre, lower(NEW.estado)), NEW.id_ruta);
    ELSIF NEW.estado = 'Habilitada' AND OLD.estado <> 'Habilitada' THEN
        UPDATE alertas SET estado = 'Resuelta', resuelta_en = now()
         WHERE id_ruta = NEW.id_ruta AND estado <> 'Resuelta';
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_ruta_alertas ON rutas;
CREATE TRIGGER trg_ruta_alertas
AFTER UPDATE OF estado ON rutas
FOR EACH ROW EXECUTE FUNCTION fn_ruta_alertas();


-- =====================================================================
-- B. VISTAS DE KPIs
-- =====================================================================

-- B1. Consumo diario consolidado (varios partes el mismo día se suman)
CREATE OR REPLACE VIEW v_consumo_diario AS
SELECT id_frente, id_insumo, fecha,
       SUM(cantidad)            AS cantidad,
       SUM(COALESCE(etapas,0))  AS etapas
  FROM consumos
 GROUP BY id_frente, id_insumo, fecha;


-- B2. Autonomía (días de cobertura) por frente e insumo.
--     Consumo real = total de los últimos 7 días cerrados / días operados.
--     Se compara contra el plan para medir el desvío.
CREATE OR REPLACE VIEW v_autonomia AS
WITH ventana AS (
    SELECT id_frente, id_insumo, SUM(cantidad) AS total_7d
      FROM v_consumo_diario
     WHERE fecha BETWEEN current_date - 7 AND current_date - 1
     GROUP BY id_frente, id_insumo
), dias_operados AS (
    SELECT id_frente, COUNT(DISTINCT fecha) AS dias
      FROM consumos
     WHERE fecha BETWEEN current_date - 7 AND current_date - 1
     GROUP BY id_frente
), base AS (
    SELECT s.id_frente, f.nombre AS frente, f.tipo AS tipo_frente,
           s.id_insumo, i.nombre AS insumo, i.categoria, i.unidad, i.critico,
           s.cantidad_actual, s.umbral_critico, s.stock_minimo, s.stock_objetivo,
           ROUND(v.total_7d / NULLIF(d.dias,0), 2)           AS consumo_real_dia,
           p.cantidad_dia                                    AS consumo_plan_dia
      FROM stock s
      JOIN frentes f  ON f.id_frente = s.id_frente
      JOIN insumos i  ON i.id_insumo = s.id_insumo
      LEFT JOIN ventana v       ON v.id_frente = s.id_frente AND v.id_insumo = s.id_insumo
      LEFT JOIN dias_operados d ON d.id_frente = s.id_frente
      LEFT JOIN consumo_plan p  ON p.id_frente = s.id_frente AND p.id_insumo = s.id_insumo
     WHERE f.estado = 'Activo'
)
SELECT b.*,
       ROUND(b.cantidad_actual / NULLIF(b.consumo_real_dia,0), 2)  AS dias_autonomia,
       ROUND(b.cantidad_actual / NULLIF(b.consumo_plan_dia,0), 2)  AS dias_autonomia_plan,
       ROUND(100.0 * (b.consumo_real_dia - b.consumo_plan_dia) / NULLIF(b.consumo_plan_dia,0), 1)
                                                                   AS desvio_plan_pct,
       ROUND(100.0 * b.cantidad_actual / b.stock_objetivo, 1)      AS pct_objetivo,
       current_date + FLOOR(b.cantidad_actual / NULLIF(b.consumo_real_dia,0))::int
                                                                   AS fecha_quiebre,
       CASE
         WHEN b.cantidad_actual <= b.umbral_critico
           OR b.cantidad_actual / NULLIF(b.consumo_real_dia,0) < 1    THEN 'Crítico'
         WHEN b.cantidad_actual <= b.stock_minimo
           OR b.cantidad_actual / NULLIF(b.consumo_real_dia,0) < 2    THEN 'Bajo'
         WHEN b.cantidad_actual <= b.stock_objetivo * 0.5
           OR b.cantidad_actual / NULLIF(b.consumo_real_dia,0) < 3    THEN 'Atención'
         ELSE 'Normal'
       END AS semaforo
  FROM base b;


-- B3. Disponibilidad de flota por frente y tipo de equipo
CREATE OR REPLACE VIEW v_disponibilidad_flota AS
SELECT fl.id_frente, f.nombre AS frente, fl.tipo,
       COUNT(*)                                                     AS total,
       COUNT(*) FILTER (WHERE fl.estado = 'Operativo')              AS operativos,
       COUNT(*) FILTER (WHERE fl.estado LIKE 'Mantenimiento%')      AS en_mantenimiento,
       COUNT(*) FILTER (WHERE fl.estado = 'Fuera de servicio')      AS fuera_servicio,
       ROUND(100.0 * COUNT(*) FILTER (WHERE fl.estado = 'Operativo') / COUNT(*), 1)
                                                                    AS disponibilidad_pct
  FROM flota fl
  JOIN frentes f ON f.id_frente = fl.id_frente
 GROUP BY fl.id_frente, f.nombre, fl.tipo;


-- B4. Balance de reposición: ¿la flota operativa alcanza a reponer lo que se consume?
CREATE OR REPLACE VIEW v_balance_reposicion AS
WITH capacidad AS (
    SELECT id_frente, id_insumo,
           SUM(capacidad * viajes_dia_max) FILTER (WHERE estado = 'Operativo') AS cap_operativa_dia,
           SUM(capacidad * viajes_dia_max)                                    AS cap_nominal_dia,
           COUNT(*) FILTER (WHERE estado <> 'Operativo')                      AS equipos_no_disp
      FROM flota
     WHERE id_insumo IS NOT NULL
     GROUP BY id_frente, id_insumo
)
SELECT a.id_frente, a.frente, a.id_insumo, a.insumo, a.unidad,
       COALESCE(a.consumo_real_dia, a.consumo_plan_dia)                 AS demanda_dia,
       COALESCE(c.cap_operativa_dia,0)                                  AS cap_operativa_dia,
       COALESCE(c.cap_nominal_dia,0)                                    AS cap_nominal_dia,
       COALESCE(c.equipos_no_disp,0)                                    AS equipos_no_disp,
       ROUND(100.0 * COALESCE(c.cap_operativa_dia,0)
             / NULLIF(COALESCE(a.consumo_real_dia, a.consumo_plan_dia),0), 1) AS cobertura_pct,
       ROUND(COALESCE(c.cap_operativa_dia,0)
             - COALESCE(a.consumo_real_dia, a.consumo_plan_dia), 2)     AS balance_dia
  FROM v_autonomia a
  JOIN capacidad c ON c.id_frente = a.id_frente AND c.id_insumo = a.id_insumo;


-- B5. Índice de sostenimiento por frente (0 a 1) e insumo limitante
CREATE OR REPLACE VIEW v_indice_sostenimiento AS
WITH ranking AS (
    SELECT a.*, ROW_NUMBER() OVER (PARTITION BY id_frente
                                   ORDER BY dias_autonomia NULLS LAST) AS rn
      FROM v_autonomia a
)
SELECT r.id_frente, r.frente, r.tipo_frente,
       ROUND(AVG(LEAST(r.cantidad_actual / r.stock_objetivo, 1)), 3)       AS indice,
       CASE
         WHEN AVG(LEAST(r.cantidad_actual / r.stock_objetivo, 1)) >= 0.80 THEN 'Óptimo'
         WHEN AVG(LEAST(r.cantidad_actual / r.stock_objetivo, 1)) >= 0.50 THEN 'Aceptable'
         WHEN AVG(LEAST(r.cantidad_actual / r.stock_objetivo, 1)) >= 0.30 THEN 'Comprometido'
         ELSE 'Crítico'
       END                                                                 AS estado,
       MIN(r.dias_autonomia)                                               AS dias_autonomia_min,
       MAX(r.insumo) FILTER (WHERE r.rn = 1 AND r.dias_autonomia IS NOT NULL) AS insumo_limitante,
       COUNT(*) FILTER (WHERE r.semaforo IN ('Crítico','Bajo'))            AS insumos_en_riesgo
  FROM ranking r
 GROUP BY r.id_frente, r.frente, r.tipo_frente;


-- B6. Rutas: riesgo efectivo según el clima del día
CREATE OR REPLACE VIEW v_rutas_estado AS
SELECT r.*,
       c.viento_kmh, c.lluvia_mm,
       LEAST(5, r.riesgo_base
              + CASE WHEN c.viento_kmh >= 70 THEN 2 WHEN c.viento_kmh >= 50 THEN 1 ELSE 0 END
              + CASE WHEN r.superficie IN ('Tierra','Ripio') AND c.lluvia_mm >= 10 THEN 2
                     WHEN c.lluvia_mm >= 3 THEN 1 ELSE 0 END)              AS riesgo_efectivo,
       CASE
         WHEN r.estado = 'Cerrada' THEN 'Cerrada'
         WHEN LEAST(5, r.riesgo_base
              + CASE WHEN c.viento_kmh >= 70 THEN 2 WHEN c.viento_kmh >= 50 THEN 1 ELSE 0 END
              + CASE WHEN r.superficie IN ('Tierra','Ripio') AND c.lluvia_mm >= 10 THEN 2
                     WHEN c.lluvia_mm >= 3 THEN 1 ELSE 0 END) >= 5 THEN 'Recomendar cierre'
         WHEN LEAST(5, r.riesgo_base
              + CASE WHEN c.viento_kmh >= 70 THEN 2 WHEN c.viento_kmh >= 50 THEN 1 ELSE 0 END
              + CASE WHEN r.superficie IN ('Tierra','Ripio') AND c.lluvia_mm >= 10 THEN 2
                     WHEN c.lluvia_mm >= 3 THEN 1 ELSE 0 END) >= 4 THEN 'Circular con restricción'
         ELSE 'Normal'
       END AS condicion
  FROM rutas r
  LEFT JOIN clima c ON c.zona = r.zona_clima AND c.fecha = current_date;


-- B7. Cumplimiento de viajes (últimos 7 días)
CREATE OR REPLACE VIEW v_viajes_kpi AS
SELECT v.id_ruta, r.nombre AS ruta, r.destino,
       COUNT(*) FILTER (WHERE v.estado = 'Entregado')                        AS entregados,
       COUNT(*) FILTER (WHERE v.estado IN ('En tránsito','Demorado'))         AS en_curso,
       COUNT(*) FILTER (WHERE v.estado = 'Cancelado')                        AS cancelados,
       ROUND(100.0 * COUNT(*) FILTER (WHERE v.estado = 'Entregado'
                                        AND v.llegada_real <= v.llegada_plan + interval '30 min')
             / NULLIF(COUNT(*) FILTER (WHERE v.estado = 'Entregado'),0), 1)  AS a_tiempo_pct,
       ROUND(AVG(EXTRACT(EPOCH FROM (v.llegada_real - v.llegada_plan))/60)
             FILTER (WHERE v.estado = 'Entregado'), 0)                       AS demora_media_min
  FROM viajes v
  JOIN rutas r ON r.id_ruta = v.id_ruta
 WHERE v.salida >= current_date - 7
 GROUP BY v.id_ruta, r.nombre, r.destino;


-- B8. Alertas activas, ordenadas por severidad
CREATE OR REPLACE VIEW v_alertas_activas AS
SELECT a.*, f.nombre AS frente,
       CASE a.severidad WHEN 'Crítica' THEN 1 WHEN 'Alta' THEN 2 WHEN 'Media' THEN 3 ELSE 4 END AS orden
  FROM alertas a
  LEFT JOIN frentes f ON f.id_frente = a.id_frente
 WHERE a.estado <> 'Resuelta'
 ORDER BY orden, a.creada_en DESC;


-- B9. Acciones sugeridas: reglas simples que traducen KPIs en decisiones.
--     urgencia = días de cobertura en juego (menor = más urgente)
CREATE OR REPLACE VIEW v_acciones_sugeridas AS
SELECT * FROM (
    -- 1) Insumos con menos de 2 días de cobertura
    SELECT 1 AS prioridad, a.dias_autonomia AS urgencia, a.id_frente, a.frente,
           format('Priorizar despacho de %s a %s: cubre %s días (quiebre estimado %s).',
                  lower(a.insumo), a.frente, ROUND(a.dias_autonomia,1), to_char(a.fecha_quiebre,'DD/MM')) AS accion
      FROM v_autonomia a
     WHERE a.dias_autonomia < 2
    UNION ALL
    -- 2) Ruta principal no transitable con alternativa habilitada
    SELECT 1, i.dias_autonomia_min + 0.01, p.destino, f.nombre,
           format('Desviar el tráfico de %s por %s (+%s km, +%s min por viaje).',
                  p.nombre, alt.nombre, ROUND(alt.distancia_km - p.distancia_km), alt.tiempo_min - p.tiempo_min)
      FROM v_rutas_estado p
      JOIN rutas alt ON alt.origen = p.origen AND alt.destino = p.destino
                    AND NOT alt.es_principal AND alt.estado = 'Habilitada'
      JOIN frentes f ON f.id_frente = p.destino
      LEFT JOIN v_indice_sostenimiento i ON i.id_frente = p.destino
     WHERE p.es_principal AND p.condicion IN ('Cerrada','Recomendar cierre')
    UNION ALL
    -- 3) Flota operativa que no alcanza a reponer el consumo
    SELECT 2, 10 + b.cobertura_pct / 100, b.id_frente, b.frente,
           format('Reforzar flota de %s para %s: la capacidad operativa cubre el %s%% del consumo (%s %s/día de déficit).',
                  lower(b.insumo), b.frente, ROUND(b.cobertura_pct), ROUND(ABS(b.balance_dia)), b.unidad)
      FROM v_balance_reposicion b
     WHERE b.cobertura_pct < 100
    UNION ALL
    -- 4) Consumo real muy por encima del plan
    SELECT 3, 20, a.id_frente, a.frente,
           format('Revisar consumo de %s en %s: %s%% sobre el plan.',
                  lower(a.insumo), a.frente, ROUND(a.desvio_plan_pct))
      FROM v_autonomia a
     WHERE a.desvio_plan_pct > 15
) x
ORDER BY urgencia NULLS LAST;


-- B10. Viajes recientes (últimas 24 h y todo lo que sigue en curso)
CREATE OR REPLACE VIEW v_viajes_recientes AS
SELECT v.*, r.nombre AS ruta, r.destino, f.nombre AS frente_destino
  FROM viajes v
  JOIN rutas r   ON r.id_ruta = v.id_ruta
  JOIN frentes f ON f.id_frente = r.destino
 WHERE v.salida >= now() - interval '24 hours'
    OR v.estado IN ('Programado','En tránsito','Demorado')
 ORDER BY v.salida DESC;
