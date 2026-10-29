-- =============================================================================
-- PASO 1 de 2 — Endurecer la seguridad (RLS) de Mesa de Ayuda
-- Fecha: 29-oct-2026
--
-- Cómo ejecutarlo: Supabase → SQL Editor → New query → pega TODO → Run.
-- Es seguro ejecutarlo más de una vez (usa "drop ... if exists" / "on conflict").
-- Todo va dentro de una transacción: si algo falla, NO se aplica nada.
--
-- IMPORTANTE: este paso NO rompe la app actual. La vista ticket_lookup se deja
-- funcionando; se elimina hasta el PASO 2, después de publicar el index.html nuevo.
-- =============================================================================
--
-- Conceptos rápidos (para entender lo que sigue):
--   * anon          = cualquier persona que abre la página, SIN iniciar sesión.
--   * authenticated = cualquier cuenta que inició sesión en Supabase Auth.
--                     ¡OJO! No es lo mismo que "administrador": si el registro
--                     de usuarios está abierto, cualquiera puede crearse una cuenta.
--   * RLS (Row Level Security) = reglas que Postgres revisa EN CADA FILA antes de
--     dejar leer/insertar/editar/borrar. Es la única protección real, porque la
--     clave publicable de Supabase está (por diseño) a la vista en el index.html.
--   * "using (...)"      = qué filas EXISTENTES puedes ver/editar/borrar.
--   * "with check (...)" = cómo deben ser las filas que INSERTAS o dejas al editar.
-- =============================================================================

begin;

-- -----------------------------------------------------------------------------
-- 1) Lista de administradores
-- Antes: cualquier "authenticated" tenía permiso total. Ahora solo las cuentas
-- que estén en esta tabla. La tabla NO tiene políticas para anon/authenticated,
-- así que nadie puede leerla ni modificarla desde la app: solo desde el SQL Editor.
-- -----------------------------------------------------------------------------
create table if not exists public.admins (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  nota       text,                       -- p. ej. el correo, para identificarla
  created_at timestamptz not null default now()
);
alter table public.admins enable row level security;
revoke all on public.admins from anon, authenticated;

-- Hoy existe UNA sola cuenta en Auth (la que usa Informática). Se agrega como admin.
-- Para dar de alta otra cuenta en el futuro:
--   insert into public.admins (user_id, nota)
--   select id, email from auth.users where email = 'correo@ejemplo.com';
insert into public.admins (user_id, nota)
select id, email from auth.users
on conflict (user_id) do nothing;

-- Función auxiliar que usan las políticas: "¿la cuenta que hace la petición es admin?"
-- security definer = corre con permisos del dueño, así puede leer "admins" aunque
-- el usuario no tenga permiso directo sobre esa tabla.
-- search_path = '' evita que alguien la engañe creando objetos con el mismo nombre.
create or replace function public.es_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.admins a where a.user_id = (select auth.uid())
  );
$$;
revoke all on function public.es_admin() from public, anon;
grant execute on function public.es_admin() to authenticated;

-- -----------------------------------------------------------------------------
-- 2) Quitar permisos que la app nunca usa
-- Supabase da por defecto TRUNCATE/TRIGGER/REFERENCES a anon y authenticated.
-- TRUNCATE (vaciar tabla) ni siquiera pasa por RLS. Nadie los necesita.
-- -----------------------------------------------------------------------------
revoke truncate, trigger, references
  on public.tickets, public.technicians, public.departments,
     public.requesters, public.push_subscriptions
  from anon, authenticated;

-- -----------------------------------------------------------------------------
-- 3) TICKETS
-- -----------------------------------------------------------------------------
drop policy if exists "admin all tickets"              on public.tickets;
drop policy if exists "Admin puede eliminar tickets"   on public.tickets;  -- duplicada
drop policy if exists "public insert tickets"          on public.tickets;
drop policy if exists "admin gestiona tickets"         on public.tickets;
drop policy if exists "publico crea tickets"           on public.tickets;

create policy "admin gestiona tickets"
  on public.tickets for all
  to authenticated
  using (public.es_admin())
  with check (public.es_admin());

-- El formulario público solo puede crear tickets "nuevos de verdad":
-- abiertos, prioridad Media, sin resolver, sin solución ni asunto, y con textos
-- de tamaño razonable. Antes, alguien podía mandar a mano un ticket ya "Cerrado",
-- "Crítico" o con una bitácora (log) inventada.
create policy "publico crea tickets"
  on public.tickets for insert
  to anon
  with check (
        status      = 'Abierto'
    and priority    = 'Media'
    and resolved_at is null
    and solucion    is null
    and asunto      is null
    and char_length(id)          between 1 and 30
    and char_length(requester)   between 1 and 120
    and char_length(department)  between 1 and 120
    and char_length(description) between 1 and 5000
    and char_length(coalesce(puesto, ''))     <= 120
    and char_length(coalesce(contacto, ''))   <= 60
    and char_length(coalesce(technician, '')) <= 120
    and (log is null or (jsonb_typeof(log) = 'array' and jsonb_array_length(log) <= 1))
  );
-- Nota: anon NO tiene política de SELECT en tickets, así que no puede leerlos.
-- Por eso el formulario público inserta con "return=minimal" (sin pedir la fila de vuelta).

-- -----------------------------------------------------------------------------
-- 4) CATÁLOGOS (técnicos, departamentos, solicitantes)
-- El público necesita LEERLOS para llenar las listas del formulario, y puede
-- AGREGAR un departamento o su nombre si no aparece. No puede editar ni borrar.
-- -----------------------------------------------------------------------------
-- technicians
drop policy if exists "admin all technicians"     on public.technicians;
drop policy if exists "public read technicians"   on public.technicians;
drop policy if exists "admin gestiona technicians" on public.technicians;
drop policy if exists "publico lee technicians"   on public.technicians;

create policy "admin gestiona technicians"
  on public.technicians for all to authenticated
  using (public.es_admin()) with check (public.es_admin());
create policy "publico lee technicians"
  on public.technicians for select to anon
  using (true);

-- departments
drop policy if exists "admin all departments"          on public.departments;
drop policy if exists "public read departments"        on public.departments;
drop policy if exists "Public can insert departments"  on public.departments;
drop policy if exists "admin gestiona departments"     on public.departments;
drop policy if exists "publico lee departments"        on public.departments;
drop policy if exists "publico agrega departments"     on public.departments;

create policy "admin gestiona departments"
  on public.departments for all to authenticated
  using (public.es_admin()) with check (public.es_admin());
create policy "publico lee departments"
  on public.departments for select to anon
  using (true);
create policy "publico agrega departments"
  on public.departments for insert to anon
  with check (char_length(name) between 2 and 120 and parent_department is null);

-- requesters
drop policy if exists "admin all requesters"       on public.requesters;
drop policy if exists "public read requesters"     on public.requesters;
drop policy if exists "public insert requesters"   on public.requesters;
drop policy if exists "admin gestiona requesters"  on public.requesters;
drop policy if exists "publico lee requesters"     on public.requesters;
drop policy if exists "publico agrega requesters"  on public.requesters;

create policy "admin gestiona requesters"
  on public.requesters for all to authenticated
  using (public.es_admin()) with check (public.es_admin());
create policy "publico lee requesters"
  on public.requesters for select to anon
  using (true);
create policy "publico agrega requesters"
  on public.requesters for insert to anon
  with check (
        char_length(name)       between 2 and 120
    and char_length(department) between 1 and 120
    and char_length(coalesce(puesto, '')) <= 120
  );

-- -----------------------------------------------------------------------------
-- 5) SUSCRIPCIONES PUSH
-- Antes: anon podía LEER todas, BORRAR todas y CREAR una propia (y así recibir
-- los avisos de tickets nuevos, con nombres de solicitantes). El botón de
-- notificaciones solo existe en el panel de administrador, así que anon no
-- necesita nada aquí. Se agrega UPDATE para el admin: "Elegir quién eres"
-- actualiza el técnico de la suscripción y antes fallaba en silencio.
-- La Edge Function send-push usa la clave service_role, que no pasa por RLS.
-- -----------------------------------------------------------------------------
drop policy if exists "anon puede suscribirse"                     on public.push_subscriptions;
drop policy if exists "anon puede borrar su suscripción"           on public.push_subscriptions;
drop policy if exists "anon puede ver si ya existe su endpoint"    on public.push_subscriptions;
drop policy if exists "authenticated puede suscribirse"            on public.push_subscriptions;
drop policy if exists "authenticated puede borrar su suscripcion"  on public.push_subscriptions;
drop policy if exists "authenticated puede ver suscripciones"      on public.push_subscriptions;
drop policy if exists "admin gestiona push_subscriptions"          on public.push_subscriptions;

create policy "admin gestiona push_subscriptions"
  on public.push_subscriptions for all to authenticated
  using (public.es_admin()) with check (public.es_admin());

-- -----------------------------------------------------------------------------
-- 6) SEGUIMIENTO PÚBLICO DE TICKETS: nueva función buscar_tickets()
-- Antes, la vista ticket_lookup corría con permisos del dueño (postgres) y dejaba
-- buscar con fragmentos: escribir "a" listaba nombre y estado de TODOS los tickets.
-- Ahora la búsqueda pasa por esta función, que solo responde a:
--   * los últimos 4 dígitos EXACTOS de un folio (del año actual; en enero
--     también del año anterior), o
--   * el NOMBRE COMPLETO exacto (sin importar mayúsculas, acentos ni espacios
--     de más), con mínimo 5 letras.
-- Y solo devuelve folio, estado y prioridad (no el nombre), que es lo que la
-- pantalla de seguimiento muestra.
-- -----------------------------------------------------------------------------
create or replace function public.buscar_tickets(consulta text)
returns table (id text, status text, priority text)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  q     text := btrim(coalesce(consulta, ''));
  hoy   date := (now() at time zone 'America/Hermosillo')::date;
  anios int[];
begin
  if q ~ '^\d{1,4}$' then
    anios := array[extract(year from hoy)::int];
    if extract(month from hoy) = 1 then
      anios := anios || (extract(year from hoy)::int - 1);
    end if;
    return query
      select t.id, t.status, t.priority
      from public.tickets t
      where t.id = any (
        select 'TK-' || a || '-' || lpad(q, 4, '0') from unnest(anios) as a
      )
      order by t.id desc;
  elsif char_length(q) >= 5 then
    return query
      select t.id, t.status, t.priority
      from public.tickets t
      where translate(regexp_replace(lower(btrim(t.requester)), '\s+', ' ', 'g'), 'áéíóúüñ', 'aeiouun')
          = translate(regexp_replace(lower(q),                  '\s+', ' ', 'g'), 'áéíóúüñ', 'aeiouun')
      order by t.id desc
      limit 50;
  end if;
  -- Cualquier otra consulta (muy corta, letras sueltas, etc.) no devuelve nada.
end;
$$;
revoke all on function public.buscar_tickets(text) from public;
grant execute on function public.buscar_tickets(text) to anon, authenticated;

commit;

-- =============================================================================
-- Comprobación (opcional): después de Run, esta consulta debe listar las
-- políticas nuevas ("admin gestiona ...", "publico ...") y ninguna vieja.
--   select tablename, policyname, roles, cmd from pg_policies
--   where schemaname = 'public' order by tablename, policyname;
-- =============================================================================
