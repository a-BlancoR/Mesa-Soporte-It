-- =============================================================================
-- PASO 3 — La base de datos asigna el folio de cada ticket
-- Fecha: 29-oct-2026
--
-- Cómo ejecutarlo: Supabase → SQL Editor → New query → pega TODO → Run.
-- Se puede ejecutar más de una vez. Es COMPATIBLE con la versión anterior de
-- index.html, así que puede aplicarse antes de publicar la app nueva.
-- =============================================================================
--
-- El problema que resuelve:
--   La app pedía el número al contador (rpc/nextval) y, si esa petición fallaba
--   (mala señal), INVENTABA un folio con los últimos 4 dígitos de la hora.
--   Así nacieron 45 folios "fuera de secuencia" (0365, 0387, ... 9986).
--   Cuando el contador llegue a esos números, el ticket nuevo chocaría con el
--   existente y NO se podría guardar.
--
-- La solución:
--   1) siguiente_folio(): toma el siguiente número del contador y, si ese folio
--      ya existe, salta al siguiente, hasta encontrar uno libre.
--   2) Un trigger (disparador) que, ANTES de guardar cada ticket, le asigna folio
--      si no trae uno o si el que trae ya está ocupado. Es la red de seguridad:
--      funciona aunque la petición venga de una versión vieja de la app.
--   3) crear_ticket(): función para el formulario público. Guarda el ticket y
--      devuelve el folio en UNA sola petición (antes eran dos: pedir número y
--      guardar). El servidor fija estado, prioridad, fecha y bitácora; el
--      público solo manda los datos que escribe en el formulario.
--
-- Reglas del folio (sin cambios para el usuario):
--   TK-<año en que se registra>-<número de 4 dígitos>, contador continuo
--   (no se reinicia cada año). Los 45 folios existentes NO se modifican.
-- =============================================================================

begin;

-- -----------------------------------------------------------------------------
-- 1) siguiente_folio()
-- Un "sequence" de Postgres es atómico: aunque lleguen 10 tickets en el mismo
-- milisegundo, cada nextval() entrega un número distinto. Por eso aquí no puede
-- haber dos tickets con el mismo número.
-- -----------------------------------------------------------------------------
create or replace function public.siguiente_folio()
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  anio  text := to_char(now() at time zone 'America/Hermosillo', 'YYYY');
  n     bigint;
  folio text;
begin
  loop
    n := nextval('public.ticket_seq');
    -- lpad recorta si el número ya tiene más de 4 cifras; por eso el "case".
    folio := 'TK-' || anio || '-' ||
             case when n < 10000 then lpad(n::text, 4, '0') else n::text end;
    exit when not exists (select 1 from public.tickets t where t.id = folio);
    -- Si existía (uno de los folios viejos "inventados"), se intenta el siguiente.
  end loop;
  return folio;
end;
$$;
-- Solo la usan el trigger y crear_ticket(); nadie la llama desde la app.
revoke all on function public.siguiente_folio() from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 2) Trigger: asigna folio antes de insertar
-- -----------------------------------------------------------------------------
create or replace function public.tickets_asignar_folio()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.id is null or btrim(new.id) = ''
     or exists (select 1 from public.tickets t where t.id = new.id) then
    new.id := public.siguiente_folio();
  end if;
  return new;
end;
$$;
revoke all on function public.tickets_asignar_folio() from public, anon, authenticated;

drop trigger if exists asignar_folio on public.tickets;
create trigger asignar_folio
  before insert on public.tickets
  for each row execute function public.tickets_asignar_folio();

-- Para que una inserción SIN id pase la política "publico crea tickets"
-- (exige char_length(id) entre 1 y 30): el trigger corre ANTES de revisar el
-- "with check", así que la fila ya llega con folio. No hay que cambiar la política.

-- -----------------------------------------------------------------------------
-- 3) crear_ticket(): una sola petición desde el formulario público
-- Corre como "security definer" (permisos del dueño), así que NO pasa por la
-- política de INSERT de anon. Por eso aquí mismo se validan los datos, y los
-- campos delicados (estado, prioridad, fechas, bitácora) los pone el servidor.
-- -----------------------------------------------------------------------------
create or replace function public.crear_ticket(
  p_requester   text,
  p_department  text,
  p_puesto      text,
  p_contacto    text,
  p_description text,
  p_technician  text default ''
)
returns table (id text, created_at timestamptz)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_req  text := btrim(coalesce(p_requester, ''));
  v_dep  text := btrim(coalesce(p_department, ''));
  v_pue  text := btrim(coalesce(p_puesto, ''));
  v_con  text := btrim(coalesce(p_contacto, ''));
  v_des  text := btrim(coalesce(p_description, ''));
  v_tec  text := btrim(coalesce(p_technician, ''));
  v_ahora timestamptz := now();
  v_id   text;
begin
  if char_length(v_req) not between 1 and 120 then raise exception 'Nombre inválido'; end if;
  if char_length(v_dep) not between 1 and 120 then raise exception 'Departamento inválido'; end if;
  if char_length(v_des) not between 1 and 5000 then raise exception 'Descripción inválida'; end if;
  if char_length(v_pue) > 120 then raise exception 'Puesto demasiado largo'; end if;
  if char_length(v_con) > 60  then raise exception 'Contacto demasiado largo'; end if;
  -- El técnico sugerido debe existir en el catálogo (o venir vacío = sin preferencia).
  if v_tec <> '' and not exists (select 1 from public.technicians t where t.name = v_tec) then
    v_tec := '';
  end if;

  insert into public.tickets
    (id, requester, department, puesto, contacto, description,
     priority, status, technician, created_at, resolved_at, log)
  values
    (null, v_req, v_dep, nullif(v_pue, ''), nullif(v_con, ''), v_des,
     'Media', 'Abierto', v_tec, v_ahora, null,
     jsonb_build_array(jsonb_build_object('at', v_ahora, 'text', 'Ticket creado por usuario')))
  returning public.tickets.id into v_id;

  return query select v_id, v_ahora;
end;
$$;
revoke all on function public.crear_ticket(text, text, text, text, text, text) from public;
grant execute on function public.crear_ticket(text, text, text, text, text, text) to anon, authenticated;

commit;

-- =============================================================================
-- Comprobación (opcional):
--   select public.siguiente_folio();   -- ¡OJO! consume un número del contador
-- Mejor: crea un ticket de prueba desde la app y revisa que el folio sea el
-- siguiente al último normal (p. ej. TK-2026-0318), luego bórralo.
-- =============================================================================
