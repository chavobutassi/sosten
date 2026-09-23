-- =====================================================================
-- SOSTÉN · Ajustes para Supabase (ejecutar después de 01, 02 y 03)
--
-- Supabase expone el esquema public por su API REST. Estas políticas
-- dejan el tablero en modo de SOLO LECTURA para la clave anon y reservan
-- las escrituras para usuarios autenticados.
-- =====================================================================

-- Las vistas respetan los permisos de quien consulta (PostgreSQL 15+)
DO $$
DECLARE v text;
BEGIN
  FOREACH v IN ARRAY ARRAY['v_consumo_diario','v_autonomia','v_disponibilidad_flota','v_balance_reposicion',
                           'v_indice_sostenimiento','v_rutas_estado','v_viajes_kpi','v_alertas_activas',
                           'v_acciones_sugeridas','v_viajes_recientes']
  LOOP
    EXECUTE format('ALTER VIEW %I SET (security_invoker = on)', v);
  END LOOP;
END $$;

-- RLS en todas las tablas, lectura para anon y authenticated
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['frentes','insumos','stock','consumo_plan','consumos','flota','rutas',
                           'clima','viajes','mantenimiento','alertas']
  LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('DROP POLICY IF EXISTS lectura ON %I', t);
    EXECUTE format('CREATE POLICY lectura ON %I FOR SELECT TO anon, authenticated USING (true)', t);
  END LOOP;
END $$;

-- Partes de consumo: solo usuarios autenticados.
-- Los triggers actualizan stock y alertas con los permisos del dueño de la función.
DROP POLICY IF EXISTS carga_partes ON consumos;
CREATE POLICY carga_partes ON consumos FOR INSERT TO authenticated WITH CHECK (true);

ALTER FUNCTION fn_consumo_descuenta_stock() SECURITY DEFINER SET search_path = public;
ALTER FUNCTION fn_stock_alertas()           SECURITY DEFINER SET search_path = public;
ALTER FUNCTION fn_viaje_mueve_stock()       SECURITY DEFINER SET search_path = public;
ALTER FUNCTION fn_flota_alertas()           SECURITY DEFINER SET search_path = public;
ALTER FUNCTION fn_ruta_alertas()            SECURITY DEFINER SET search_path = public;

-- Para una demo pública donde cualquiera pueda cargar partes con la clave anon,
-- descomentá la línea siguiente (no recomendado con datos reales):
-- CREATE POLICY carga_partes_demo ON consumos FOR INSERT TO anon WITH CHECK (true);
