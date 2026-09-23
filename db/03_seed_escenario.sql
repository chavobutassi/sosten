-- =====================================================================
-- SOSTÉN · Escenario de demostración "Frente Loma Alta"
--
-- Operadora y bloques FICTICIOS. Volúmenes en órdenes de magnitud
-- típicos de una fractura no convencional (ver README). Todas las
-- fechas son relativas a current_date: la demo nunca queda vieja.
--
-- Situación: el Set de fractura 1 (Loma Alta) opera a 85 km de la base.
-- El gasoil cubre menos de un día, la arena menos de dos, dos camiones
-- areneros están fuera de servicio por falta de repuestos y el viento
-- cerró el camino principal. Existe una variante habilitada.
-- =====================================================================

BEGIN;

TRUNCATE alertas, mantenimiento, viajes, clima, rutas, flota,
         consumos, consumo_plan, stock, insumos, frentes RESTART IDENTITY CASCADE;

-- ---------------------------------------------------------------------
-- Frentes
-- ---------------------------------------------------------------------
INSERT INTO frentes (id_frente, nombre, tipo, bloque, lat, lon, dotacion, etapas_plan_dia, base_apoyo) VALUES
('BASE-ANE', 'Base logística Añelo',              'Base logística',        NULL,          -38.3540, -68.7880, 60,  NULL, NULL),
('FS-01',    'Set de fractura 1 · Loma Alta',    'Set de fractura',       'Loma Alta',   -38.0450, -69.3120, 85,  9,    'BASE-ANE'),
('FS-02',    'Set de fractura 2 · Cerro Negro',  'Set de fractura',       'Cerro Negro', -38.5120, -69.4380, 80,  8,    'BASE-ANE'),
('PE-01',    'Equipo de perforación 1 · Bajada Sur','Equipo de perforación','Bajada Sur', -38.7430, -68.9900, 45,  NULL, 'BASE-ANE'),
('CAMP-01',  'Campamento Loma Alta',             'Campamento',            'Loma Alta',   -38.2150, -69.1250, 140, NULL, 'BASE-ANE');

-- ---------------------------------------------------------------------
-- Insumos
-- ---------------------------------------------------------------------
INSERT INTO insumos VALUES
('ARENA',  'Arena de fractura',       'Agente de sostén', 't',        true),
('AGUA',   'Agua de fractura',        'Agua',             'm³',       true),
('GASOIL', 'Gasoil',                  'Combustible',      'm³',       true),
('QUIM',   'Aditivos químicos',       'Químicos',         'm³',       true),
('VIANDA', 'Viandas',                 'Campamento',       'raciones', false),
('AGUAP',  'Agua potable',            'Campamento',       'm³',       false);

-- ---------------------------------------------------------------------
-- Consumo planificado (programa de trabajo)
-- ---------------------------------------------------------------------
INSERT INTO consumo_plan VALUES
('FS-01','ARENA', 2250,  'Programa de fractura: 9 etapas/día × 250 t'),
('FS-01','AGUA',  10800, 'Programa de fractura: 9 etapas/día × 1.200 m³'),
('FS-01','GASOIL',72,    'Flota de bombeo + generación'),
('FS-01','QUIM',  45,    'Programa de fractura'),
('FS-02','ARENA', 2000,  'Programa de fractura: 8 etapas/día × 250 t'),
('FS-02','AGUA',  9600,  'Programa de fractura: 8 etapas/día × 1.200 m³'),
('FS-02','GASOIL',64,    'Flota de bombeo + generación'),
('FS-02','QUIM',  40,    'Programa de fractura'),
('PE-01','GASOIL',9,     'Equipo de perforación'),
('PE-01','AGUA',  60,    'Preparación de lodo'),
('CAMP-01','VIANDA',420, '140 personas × 3 comidas'),
('CAMP-01','AGUAP', 21,  '140 personas × 150 l'),
('CAMP-01','GASOIL',6,   'Generadores del campamento');

-- ---------------------------------------------------------------------
-- Stock: se carga alto, se registran los consumos (el trigger descuenta)
-- y al final se fija el nivel actual; los cruces de umbral generan alertas.
-- ---------------------------------------------------------------------
INSERT INTO stock (id_frente, id_insumo, cantidad_actual, umbral_critico, stock_minimo, stock_objetivo) VALUES
('BASE-ANE','ARENA', 999999, 6000,  12000, 30000),
('BASE-ANE','GASOIL',999999, 150,   300,   800),
('BASE-ANE','QUIM',  999999, 80,    150,   400),
('FS-01','ARENA',    999999, 2250,  4500,  9000),
('FS-01','AGUA',     999999, 11000, 22000, 45000),
('FS-01','GASOIL',   999999, 75,    150,   300),
('FS-01','QUIM',     999999, 45,    90,    220),
('FS-02','ARENA',    999999, 2000,  4000,  8000),
('FS-02','AGUA',     999999, 10000, 20000, 40000),
('FS-02','GASOIL',   999999, 65,    130,   260),
('FS-02','QUIM',     999999, 40,    80,    200),
('PE-01','GASOIL',   999999, 9,     18,    45),
('PE-01','AGUA',     999999, 60,    120,   360),
('CAMP-01','VIANDA', 999999, 420,   840,   2520),
('CAMP-01','AGUAP',  999999, 21,    42,    105),
('CAMP-01','GASOIL', 999999, 6,     12,    36);

-- Partes diarios de los últimos 14 días. Variación determinística
-- (seno) + sesgo por frente/insumo para que el desvío sea visible.
INSERT INTO consumos (id_frente, id_insumo, fecha, cantidad, etapas, actividad, reportado_por)
SELECT p.id_frente, p.id_insumo, current_date - d,
       ROUND((p.cantidad_dia * (1 + sesgo.valor
             + 0.05 * sin(d * 1.7 + length(p.id_frente || p.id_insumo))))::numeric, 1),
       CASE WHEN p.id_insumo = 'ARENA'
            THEN ROUND((f.etapas_plan_dia * (1 + 0.06 * sin(d * 1.3 + length(p.id_frente))))::numeric)
       END,
       CASE f.tipo WHEN 'Set de fractura' THEN 'Fractura'
                   WHEN 'Equipo de perforación' THEN 'Perforación'
                   ELSE 'Operación de campamento' END,
       'Parte diario ' || p.id_frente
  FROM consumo_plan p
  JOIN frentes f ON f.id_frente = p.id_frente
  CROSS JOIN generate_series(1, 14) AS d
  JOIN LATERAL (SELECT CASE p.id_frente || ':' || p.id_insumo
                         WHEN 'FS-01:ARENA'  THEN 0.07   -- más arena por etapa que la diseñada
                         WHEN 'FS-01:GASOIL' THEN 0.12   -- esperas con motores en marcha por viento
                         WHEN 'FS-01:AGUA'   THEN -0.03
                         WHEN 'FS-02:ARENA'  THEN 0.02
                         WHEN 'CAMP-01:AGUAP' THEN 0.10
                         ELSE 0 END AS valor) sesgo ON true;

-- Nivel actual de stock (dispara alertas por cruce de umbral)
UPDATE stock s SET cantidad_actual = v.actual
  FROM (VALUES
    ('BASE-ANE','ARENA', 11200), ('BASE-ANE','GASOIL', 520), ('BASE-ANE','QUIM', 310),
    ('FS-01','ARENA',    3800),  ('FS-01','AGUA',     31500), ('FS-01','GASOIL', 70),  ('FS-01','QUIM', 205),
    ('FS-02','ARENA',    7400),  ('FS-02','AGUA',     38500), ('FS-02','GASOIL', 235), ('FS-02','QUIM', 185),
    ('PE-01','GASOIL',   38),    ('PE-01','AGUA',     290),
    ('CAMP-01','VIANDA', 1900),  ('CAMP-01','AGUAP',  40),    ('CAMP-01','GASOIL', 31)
  ) AS v(frente, insumo, actual)
 WHERE s.id_frente = v.frente AND s.id_insumo = v.insumo;

-- ---------------------------------------------------------------------
-- Flota (dedicada a cada frente, cicla desde la base)
-- ---------------------------------------------------------------------
INSERT INTO flota (id_equipo, id_frente, tipo, id_insumo, capacidad, viajes_dia_max, horas_uso, ultimo_mant)
SELECT 'ARE-' || lpad(n::text, 3, '0'),
       CASE WHEN n <= 26 THEN 'FS-01' ELSE 'FS-02' END,
       'Camión arenero', 'ARENA', 30,
       CASE WHEN n <= 26 THEN 3 ELSE 3.2 END,
       1800 + (n * 137) % 2600,
       current_date - (n * 11) % 60
  FROM generate_series(1, 50) AS n;

INSERT INTO flota (id_equipo, id_frente, tipo, id_insumo, capacidad, viajes_dia_max, horas_uso, ultimo_mant) VALUES
('CGO-001','FS-01','Cisterna de gasoil','GASOIL',30,1.5,3100,current_date-20),
('CGO-002','FS-01','Cisterna de gasoil','GASOIL',30,1.5,2800,current_date-34),
('CGO-003','FS-01','Cisterna de gasoil','GASOIL',30,1.5,1900,current_date-8),
('CGO-004','FS-02','Cisterna de gasoil','GASOIL',30,1.6,2500,current_date-15),
('CGO-005','FS-02','Cisterna de gasoil','GASOIL',30,1.6,2200,current_date-41),
('CGO-006','PE-01','Cisterna de gasoil','GASOIL',20,1.0,1700,current_date-12),
('CGO-007','CAMP-01','Cisterna de gasoil','GASOIL',10,1.0,900,current_date-25),
('AQ-01',  'FS-01','Bombeo de acueducto','AGUA',11000,1,NULL,current_date-30),
('AQ-02',  'FS-02','Bombeo de acueducto','AGUA',10000,1,NULL,current_date-30),
('CAG-001','PE-01','Cisterna de agua','AGUA',30,2,1400,current_date-18),
('CVI-001','CAMP-01','Camión de viandas','VIANDA',500,1,1200,current_date-9),
('CVI-002','CAMP-01','Camión de viandas','VIANDA',500,1,1350,current_date-44),
('CAP-001','CAMP-01','Cisterna de agua potable','AGUAP',15,2,800,current_date-22),
('QUI-001','FS-01','Camión de químicos','QUIM',25,2,1600,current_date-19),
('QUI-002','FS-02','Camión de químicos','QUIM',25,2,1500,current_date-27);

INSERT INTO flota (id_equipo, id_frente, tipo, capacidad, horas_uso, ultimo_mant)
SELECT 'BOM-' || lpad(n::text, 3, '0'),
       CASE WHEN n <= 14 THEN 'FS-01' ELSE 'FS-02' END,
       'Bomba de fractura', NULL, 3000 + (n * 211) % 4000, current_date - (n * 7) % 45
  FROM generate_series(1, 26) AS n;

-- Novedades de flota (disparan alertas)
UPDATE flota SET estado = 'Fuera de servicio'       WHERE id_equipo IN ('ARE-007','ARE-019');
UPDATE flota SET estado = 'Mantenimiento correctivo' WHERE id_equipo IN ('ARE-023','BOM-005');
UPDATE flota SET estado = 'Mantenimiento preventivo' WHERE id_equipo IN ('ARE-041','CGO-002');

INSERT INTO mantenimiento (id_equipo, tipo, inicio, descripcion, repuesto_pendiente) VALUES
('ARE-007','Correctivo', now() - interval '3 days', 'Caja de cambios: falta repuesto', true),
('ARE-019','Correctivo', now() - interval '2 days', 'Suspensión delantera: repuesto en tránsito', true),
('ARE-023','Correctivo', now() - interval '20 hours', 'Pérdida de aire en sistema de frenos', false),
('BOM-005','Correctivo', now() - interval '1 day', 'Cambio de válvulas del fluid end', false),
('ARE-041','Preventivo', now() - interval '6 hours', 'Service 250 h', false),
('CGO-002','Preventivo', now() - interval '5 hours', 'Service 250 h', false);

-- ---------------------------------------------------------------------
-- Rutas
-- ---------------------------------------------------------------------
INSERT INTO rutas VALUES
('R-01',  'BASE-ANE','FS-01',  'Camino principal Loma Alta',   85,  'Mixta',   150, 2, true,  'Loma Alta',   'Habilitada'),
('R-01B', 'BASE-ANE','FS-01',  'Variante picada norte',         118, 'Ripio',   205, 3, false, 'Añelo norte', 'Habilitada'),
('R-02',  'BASE-ANE','FS-02',  'Ruta asfaltada Cerro Negro',    72,  'Asfalto', 95,  1, true,  'Añelo',       'Habilitada'),
('R-03',  'BASE-ANE','PE-01',  'Camino Bajada Sur',             64,  'Tierra',  120, 2, true,  'Bajada Sur',  'Habilitada'),
('R-04',  'BASE-ANE','CAMP-01','Acceso campamento Loma Alta',   80,  'Mixta',   140, 2, true,  'Loma Alta',   'Habilitada'),
('R-04B', 'BASE-ANE','CAMP-01','Variante picada norte (camp.)', 112, 'Ripio',   195, 3, false, 'Añelo norte', 'Habilitada');

-- Clima: 14 días hacia atrás + hoy + 2 días de pronóstico
INSERT INTO clima (zona, fecha, viento_kmh, lluvia_mm, temp_min_c)
SELECT z.zona, current_date + d,
       ROUND((z.viento + 14 * sin(d * 0.9 + z.fase))::numeric, 1),
       GREATEST(0, ROUND((z.lluvia * sin(d * 0.6 + z.fase))::numeric, 1)),
       ROUND((4 + 3 * sin(d * 0.5))::numeric, 1)
  FROM (VALUES ('Loma Alta', 45, 5, 0.3), ('Añelo norte', 35, 3, 1.1),
               ('Añelo', 32, 2, 2.0),     ('Bajada Sur', 40, 4, 2.6)) AS z(zona, viento, lluvia, fase)
  CROSS JOIN generate_series(-14, 2) AS d
 WHERE d <> 0;

INSERT INTO clima (zona, fecha, viento_kmh, lluvia_mm, temp_min_c) VALUES
('Loma Alta',   current_date, 78, 12, 3),
('Añelo norte', current_date, 44, 2,  4),
('Añelo',       current_date, 38, 1,  5),
('Bajada Sur',  current_date, 56, 4,  4);

-- ---------------------------------------------------------------------
-- Viajes: histórico de 7 días + situación de hoy
-- ---------------------------------------------------------------------
INSERT INTO viajes (id_ruta, id_equipo, id_insumo, cantidad, salida, llegada_plan, llegada_real, estado)
SELECT r.id_ruta, fl.id_equipo, fl.id_insumo, fl.capacidad,
       s.salida,
       s.salida + make_interval(mins => r.tiempo_min),
       s.salida + make_interval(mins => r.tiempo_min
                  + CASE WHEN (fl.horas_uso::int + d + k) % 5 = 0 THEN 55     -- demora
                         WHEN (fl.horas_uso::int + d + k) % 3 = 0 THEN 20
                         ELSE -5 END),
       'Entregado'
  FROM flota fl
  JOIN rutas r ON r.destino = fl.id_frente AND r.es_principal
  CROSS JOIN generate_series(1, 7) AS d
  CROSS JOIN LATERAL generate_series(1, GREATEST(1, FLOOR(fl.viajes_dia_max)::int)) AS k
  CROSS JOIN LATERAL (SELECT current_date - d
                             + make_interval(hours => 5 + (k - 1) * 6 + (length(fl.id_equipo) + d) % 3) AS salida) s
 WHERE fl.id_insumo IS NOT NULL AND fl.tipo <> 'Bombeo de acueducto';

-- Hoy: ruta principal a FS-01 cerrada, viajes desviados o cancelados
INSERT INTO viajes (id_ruta, id_equipo, id_insumo, cantidad, salida, llegada_plan, estado) VALUES
('R-01B','CGO-001','GASOIL',30, now() - interval '2 hours',  now() + interval '85 min', 'En tránsito'),
('R-01B','ARE-002','ARENA', 30, now() - interval '3 hours',  now() + interval '25 min', 'En tránsito'),
('R-01B','ARE-004','ARENA', 30, now() - interval '4 hours',  now() - interval '35 min', 'Demorado'),
('R-01', 'ARE-009','ARENA', 30, now() - interval '5 hours',  now() - interval '150 min','Cancelado'),
('R-01', 'CGO-003','GASOIL',30, now() - interval '5 hours',  now() - interval '150 min','Cancelado'),
('R-02', 'ARE-031','ARENA', 30, now() - interval '1 hour',   now() + interval '35 min', 'En tránsito');

-- Cierre del camino principal por viento (dispara alerta crítica)
UPDATE rutas SET estado = 'Cerrada' WHERE id_ruta = 'R-01';

-- Alerta cargada manualmente por el supervisor
INSERT INTO alertas (id_frente, tipo, severidad, descripcion)
VALUES ('FS-01', 'Clima', 'Media', 'Pronóstico de ráfagas superiores a 70 km/h en Loma Alta por 24 h');

COMMIT;
