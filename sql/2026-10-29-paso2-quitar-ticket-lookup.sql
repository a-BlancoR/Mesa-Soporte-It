-- =============================================================================
-- PASO 2 de 2 — Eliminar la vista ticket_lookup
-- Fecha: 29-oct-2026
--
-- ¡Ejecutar SOLO DESPUÉS de que el index.html nuevo esté publicado en GitHub Pages!
-- (el que busca con la función buscar_tickets). Si lo ejecutas antes, la pantalla
-- "Seguimiento de ticket" de la versión vieja dejará de encontrar resultados.
--
-- Cómo comprobar que ya está publicado: abre la app, F12 → Network, haz una
-- búsqueda en "Seguimiento de ticket" y verifica que la petición vaya a
-- "rpc/buscar_tickets" y no a "ticket_lookup".
--
-- Por qué eliminarla: corre con los permisos de su dueño (postgres), así que
-- cualquiera podía consultarla directo, con cualquier filtro, y obtener nombre
-- y estado de todos los tickets. Supabase la marca como error de seguridad
-- ("Security Definer View").
-- =============================================================================

drop view if exists public.ticket_lookup;
