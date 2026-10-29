-- =============================================================================
-- PASO 5 — Defensas contra bots y scripts + registro de origen (auditoría)
-- Fecha: 29-oct-2026
--
-- Se puede ejecutar más de una vez. Compatible con el index.html publicado.
-- =============================================================================
--
-- Por qué en la BASE DE DATOS y no en la página:
--   Un script no usa la página: manda peticiones directo a la API de Supabase
--   con la clave publicable (que está a la vista en el index.html). Todo lo que
--   se ponga solo en la página (botones deshabilitados, validaciones en
--   JavaScript) se lo salta. Las reglas que viven en Postgres NO se las salta
--   nadie, venga de donde venga la petición.
--
-- Qué agrega:
--   1) registro_actividad: guarda IP, navegador (user-agent) y hora de cada
--      ticket creado (público o desde el panel), cada alta en catálogos y cada
--      búsqueda pública. Solo los admins pueden leerla. Sirve para:
--        * contar peticiones y aplicar límites (punto 2), y
--        * AUDITAR: saber desde qué equipo/red se creó cada ticket.
--   2) Límites de frecuencia para el público (los admins no tienen límite):
--        tickets   : 6 por IP en 10 min · 30 por IP al día · 60 en total por hora
--                    · 5 del mismo solicitante en 30 min
--        catálogos : nombres 5/IP por hora y 40 al día; departamentos 3/IP por
--                    hora y 10 al día
--        búsquedas : 30 por IP en 10 min
--      Calibrados con el historial real: el máximo de tickets públicos en un
--      día fue 8 (todas las IPs juntas). Si se rebasa, la API responde
--      HTTP 429 ("demasiadas solicitudes") con un mensaje en español.
--   3) Formato de nombres y departamentos nuevos desde el público: solo
--      letras/espacios (sin URLs, números ni símbolos) y nombre de 2+ palabras.
--   4) crear_ticket() acepta dos datos del formulario: un campo "trampa"
--      invisible (honeypot) que una persona nunca llena pero un bot sí, y los
--      milisegundos que tardó en llenarse (un humano tarda más de 3 s).
--   5) Se retira rpc/nextval para el público (la app ya no lo usa).
-- =============================================================================

begin;

-- -----------------------------------------------------------------------------
-- 1) Tabla de actividad (auditoría + base para los límites)
-- -----------------------------------------------------------------------------
create table if not exists public.registro_actividad (
  id         bigint generated always as identity primary key,
  accion     text        not null,  -- ticket_publico | ticket_panel | catalogo_solicitante | catalogo_depto | busqueda
  ip         text,
  user_agent text,
  es_admin   boolean     not null default false,
  ticket_id  text,
  detalle    text,                  -- p. ej. nombre del solicitante en minúsculas
  creado     timestamptz not null default now()
);
create index if not exists registro_actividad_limites
  on public.registro_actividad (accion, ip, creado desc);
create index if not exists registro_actividad_detalle
  on public.registro_actividad (accion, detalle, creado desc);

alter table public.registro_actividad enable row level security;
revoke all on public.registro_actividad from anon, authenticated;
grant select on public.registro_actividad to authenticated;
drop policy if exists "admin lee registro_actividad" on public.registro_actividad;
create policy "admin lee registro_actividad"
  on public.registro_actividad for select to authenticated
  using (public.es_admin());
-- Nadie escribe directo: solo las funciones de abajo (security definer).

-- IP del cliente. Supabase pasa los encabezados HTTP de la petición a Postgres
-- en la variable request.headers; "cf-connecting-ip" es la IP real del cliente.
create or replace function public.cliente_ip()
returns text
language sql
stable
set search_path = ''
as $$
  select coalesce(
    nullif(current_setting('request.headers', true), '')::json ->> 'cf-connecting-ip',
    split_part(nullif(current_setting('request.headers', true), '')::json ->> 'x-forwarded-for', ',', 1),
    'desconocida');
$$;

create or replace function public.cliente_agente()
returns text
language sql
stable
set search_path = ''
as $$
  select left(nullif(current_setting('request.headers', true), '')::json ->> 'user-agent', 300);
$$;

create or replace function public.registrar_actividad(p_accion text, p_ticket text default null, p_detalle text default null)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  insert into public.registro_actividad (accion, ip, user_agent, es_admin, ticket_id, detalle)
  values (p_accion, public.cliente_ip(), public.cliente_agente(), public.es_admin(), p_ticket, p_detalle);
  -- Limpieza ocasional (≈1 de cada 100 llamadas): las búsquedas se guardan 30 días.
  if random() < 0.01 then
    delete from public.registro_actividad
    where accion = 'busqueda' and creado < now() - interval '30 days';
  end if;
end;
$$;

-- Lanza HTTP 429 si ya se alcanzó el máximo en la ventana de tiempo.
-- PostgREST convierte el código de error 'PT429' en la respuesta HTTP 429.
create or replace function public.verificar_limite(
  p_accion  text,
  p_max     int,
  p_ventana interval,
  p_por_ip  boolean,
  p_mensaje text,
  p_detalle text default null
)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  n int;
begin
  select count(*) into n
  from public.registro_actividad r
  where r.accion = p_accion
    and r.creado > now() - p_ventana
    and (not p_por_ip or r.ip = public.cliente_ip())
    and (p_detalle is null or r.detalle = p_detalle);
  if n >= p_max then
    raise exception using errcode = 'PT429', message = p_mensaje,
      hint = 'Límite: ' || p_max || ' en ' || p_ventana::text;
  end if;
end;
$$;

revoke all on function public.registrar_actividad(text, text, text) from public, anon, authenticated;
revoke all on function public.verificar_limite(text, int, interval, boolean, text, text) from public, anon, authenticated;
revoke all on function public.cliente_ip() from public, anon, authenticated;
revoke all on function public.cliente_agente() from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 2) Límites y auditoría en TICKETS (cubre crear_ticket y cualquier INSERT directo)
-- Los triggers se ejecutan en orden alfabético: "aa_limite_publico" corre ANTES
-- que "asignar_folio", así un intento bloqueado no gasta folio.
-- -----------------------------------------------------------------------------
create or replace function public.tickets_limite_publico()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  msg text := 'Se recibieron demasiadas solicitudes desde tu red. Espera unos minutos o llama a Informática.';
begin
  if public.es_admin() then return new; end if;
  perform public.verificar_limite('ticket_publico', 6,  interval '10 minutes', true,  msg);
  perform public.verificar_limite('ticket_publico', 30, interval '1 day',      true,  msg);
  perform public.verificar_limite('ticket_publico', 60, interval '1 hour',     false,
          'El sistema está recibiendo demasiadas solicitudes. Intenta en unos minutos o llama a Informática.');
  perform public.verificar_limite('ticket_publico', 5,  interval '30 minutes', false,
          'Ya registraste varias solicitudes en poco tiempo. Si es urgente, llama a Informática.',
          lower(btrim(new.requester)));
  return new;
end;
$$;

create or replace function public.tickets_registrar_origen()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.registrar_actividad(
    case when public.es_admin() then 'ticket_panel' else 'ticket_publico' end,
    new.id, lower(btrim(new.requester)));
  return null;
end;
$$;
revoke all on function public.tickets_limite_publico() from public, anon, authenticated;
revoke all on function public.tickets_registrar_origen() from public, anon, authenticated;

drop trigger if exists aa_limite_publico on public.tickets;
create trigger aa_limite_publico
  before insert on public.tickets
  for each row execute function public.tickets_limite_publico();

drop trigger if exists registrar_origen on public.tickets;
create trigger registrar_origen
  after insert on public.tickets
  for each row execute function public.tickets_registrar_origen();

-- -----------------------------------------------------------------------------
-- 3) Catálogos: límites + formato (solo para el público)
-- -----------------------------------------------------------------------------
create or replace function public.catalogo_control_publico()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  letras constant text := 'A-Za-zÁÉÍÓÚÜÑáéíóúüñ';
  msg    constant text := 'Se agregaron demasiados registros desde tu red. Espera un momento o pide a Informática que te dé de alta.';
begin
  if public.es_admin() then return new; end if;

  if tg_table_name = 'requesters' then
    -- Nombre de persona: solo letras, espacios, punto, apóstrofo o guion; 2+ palabras.
    if new.name !~ ('^[' || letras || '][' || letras || ' .''-]*[' || letras || '.]$')
       or btrim(new.name) !~ '\s' then
      raise exception using errcode = '22023',
        message = 'Escribe tu nombre completo (nombre y apellido), solo con letras.';
    end if;
    perform public.verificar_limite('catalogo_solicitante', 5,  interval '1 hour', true,  msg);
    perform public.verificar_limite('catalogo_solicitante', 40, interval '1 day',  false, msg);
  elsif tg_table_name = 'departments' then
    if new.name !~ ('^[' || letras || '][' || letras || '0-9 .,()/-]*$') then
      raise exception using errcode = '22023',
        message = 'El nombre del departamento solo puede llevar letras, números y espacios.';
    end if;
    perform public.verificar_limite('catalogo_depto', 3,  interval '1 hour', true,  msg);
    perform public.verificar_limite('catalogo_depto', 10, interval '1 day',  false, msg);
  end if;
  return new;
end;
$$;

create or replace function public.catalogo_registrar_origen()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.registrar_actividad(
    case tg_table_name when 'requesters' then 'catalogo_solicitante' else 'catalogo_depto' end,
    null, new.name);
  return null;
end;
$$;
revoke all on function public.catalogo_control_publico() from public, anon, authenticated;
revoke all on function public.catalogo_registrar_origen() from public, anon, authenticated;

drop trigger if exists aa_control_publico on public.requesters;
create trigger aa_control_publico before insert on public.requesters
  for each row execute function public.catalogo_control_publico();
drop trigger if exists registrar_origen on public.requesters;
create trigger registrar_origen after insert on public.requesters
  for each row execute function public.catalogo_registrar_origen();

drop trigger if exists aa_control_publico on public.departments;
create trigger aa_control_publico before insert on public.departments
  for each row execute function public.catalogo_control_publico();
drop trigger if exists registrar_origen on public.departments;
create trigger registrar_origen after insert on public.departments
  for each row execute function public.catalogo_registrar_origen();

-- -----------------------------------------------------------------------------
-- 4) crear_ticket() con campo trampa (honeypot) y tiempo de llenado
-- Se reemplaza la versión de 6 parámetros por una de 8; los dos nuevos tienen
-- valor por defecto, así la app publicada (que manda 6) sigue funcionando.
-- -----------------------------------------------------------------------------
drop function if exists public.crear_ticket(text, text, text, text, text, text);

create or replace function public.crear_ticket(
  p_requester   text,
  p_department  text,
  p_puesto      text,
  p_contacto    text,
  p_description text,
  p_technician  text default '',
  p_sitio       text default null,  -- campo trampa: invisible para personas; si trae algo, es un bot
  p_ms          int  default null   -- milisegundos desde que se mostró el formulario
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
  if coalesce(btrim(p_sitio), '') <> '' then
    raise exception using errcode = '22023', message = 'No se pudo enviar la solicitud.';
  end if;
  if p_ms is not null and p_ms < 3000 then
    raise exception using errcode = '22023',
      message = 'El formulario se envió demasiado rápido. Revisa tus datos y vuelve a intentarlo.';
  end if;

  if char_length(v_req) not between 1 and 120 then raise exception 'Nombre inválido'; end if;
  if char_length(v_dep) not between 1 and 120 then raise exception 'Departamento inválido'; end if;
  if char_length(v_des) not between 1 and 5000 then raise exception 'Descripción inválida'; end if;
  if char_length(v_pue) > 120 then raise exception 'Puesto demasiado largo'; end if;
  if char_length(v_con) > 60  then raise exception 'Contacto demasiado largo'; end if;
  if v_tec <> '' and not exists (select 1 from public.technicians t where t.name = v_tec) then
    v_tec := '';
  end if;

  -- Los límites de frecuencia los aplica el trigger aa_limite_publico.
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
revoke all on function public.crear_ticket(text, text, text, text, text, text, text, int) from public;
grant execute on function public.crear_ticket(text, text, text, text, text, text, text, int) to anon, authenticated;

-- -----------------------------------------------------------------------------
-- 5) Búsqueda pública con límite (30 por IP en 10 minutos)
-- Pasa de STABLE a VOLATILE porque ahora escribe en registro_actividad
-- (PostgREST ejecuta las funciones STABLE en modo solo-lectura).
-- -----------------------------------------------------------------------------
create or replace function public.buscar_tickets(consulta text)
returns table (id text, status text, priority text)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  q     text := btrim(coalesce(consulta, ''));
  hoy   date := (now() at time zone 'America/Hermosillo')::date;
  anios int[];
  m     text[];
  num   text;
begin
  if not public.es_admin() then
    perform public.verificar_limite('busqueda', 30, interval '10 minutes', true,
      'Hiciste demasiadas búsquedas seguidas. Espera unos minutos e intenta de nuevo.');
    perform public.registrar_actividad('busqueda', null, left(q, 60));
  end if;

  m := regexp_match(upper(q), '^TK[\s-]*(\d{4})[\s-]*(\d{1,6})$');
  if m is not null then
    num := case when char_length(m[2]) < 4 then lpad(m[2], 4, '0') else m[2] end;
    return query
      select t.id, t.status, t.priority from public.tickets t
      where t.id = 'TK-' || m[1] || '-' || num;
    return;
  end if;

  if q ~ '^\d{1,6}$' then
    num := case when char_length(q) < 4 then lpad(q, 4, '0') else q end;
    anios := array[extract(year from hoy)::int];
    if extract(month from hoy) = 1 then
      anios := anios || (extract(year from hoy)::int - 1);
    end if;
    return query
      select t.id, t.status, t.priority from public.tickets t
      where t.id = any (select 'TK-' || a || '-' || num from unnest(anios) as a)
      order by t.id desc;
    return;
  end if;

  if char_length(q) >= 5 then
    return query
      select t.id, t.status, t.priority from public.tickets t
      where translate(regexp_replace(lower(btrim(t.requester)), '\s+', ' ', 'g'), 'áéíóúüñ', 'aeiouun')
          = translate(regexp_replace(lower(q),                  '\s+', ' ', 'g'), 'áéíóúüñ', 'aeiouun')
      order by t.id desc
      limit 50;
  end if;
end;
$$;
revoke all on function public.buscar_tickets(text) from public;
grant execute on function public.buscar_tickets(text) to anon, authenticated;

-- -----------------------------------------------------------------------------
-- 6) rpc/nextval ya no es necesario para el público
-- (La app usa crear_ticket desde el PR #3. Una pestaña muy vieja que aún lo
--  llame cae en su folio de respaldo y el trigger asignar_folio lo corrige.)
-- -----------------------------------------------------------------------------
-- En Postgres toda función nueva se puede ejecutar por "PUBLIC" (todos los roles),
-- así que hay que quitar el permiso a PUBLIC y a anon, y dejarlo solo a authenticated.
revoke execute on function public.nextval(text) from public, anon;
grant execute on function public.nextval(text) to authenticated;

commit;

-- =============================================================================
-- CONSULTAS ÚTILES (para el administrador, en el SQL Editor)
--
-- ¿Desde qué IP / navegador se creó cada ticket reciente?
--   select creado at time zone 'America/Hermosillo' as hora, accion, ticket_id,
--          detalle as solicitante, ip, user_agent
--   from public.registro_actividad
--   where accion in ('ticket_publico','ticket_panel')
--   order by creado desc limit 50;
--
-- ¿Alguien está mandando muchas cosas? (agrupado por IP, últimas 24 h)
--   select ip, accion, count(*) from public.registro_actividad
--   where creado > now() - interval '1 day'
--   group by ip, accion order by count(*) desc;
-- =============================================================================
