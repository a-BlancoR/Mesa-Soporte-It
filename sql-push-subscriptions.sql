-- Ejecutar en Supabase → SQL Editor → New query → Run

create table push_subscriptions (
  id bigint generated always as identity primary key,
  technician text,              -- a quién pertenece este celular (puede ser null = "todos")
  endpoint text not null unique,-- identifica el dispositivo/navegador, lo da el navegador
  p256dh text not null,         -- llave de cifrado, la da el navegador
  auth text not null,           -- llave de cifrado, la da el navegador
  created_at timestamptz default now()
);

-- Deja que cualquiera (anon) inserte/borre su propia suscripción desde la app.
-- El Edge Function usa la llave de servicio (service_role) y no pasa por RLS.
alter table push_subscriptions enable row level security;

create policy "anon puede suscribirse"
  on push_subscriptions for insert
  to anon
  with check (true);

create policy "anon puede borrar su suscripción"
  on push_subscriptions for delete
  to anon
  using (true);

create policy "anon puede ver si ya existe su endpoint"
  on push_subscriptions for select
  to anon
  using (true);
