-- Ejecutar DESPUÉS de sql-push-subscriptions.sql, en el mismo SQL Editor.
-- Necesario porque el panel de administrador de Mesa de Ayuda inicia sesión
-- con Supabase Auth (correo/contraseña), así que llega como "authenticated",
-- no como "anon". Sin esto, el botón de notificaciones fallará silenciosamente
-- al intentar guardar la suscripción.

create policy "authenticated puede suscribirse"
  on push_subscriptions for insert
  to authenticated
  with check (true);

create policy "authenticated puede borrar su suscripcion"
  on push_subscriptions for delete
  to authenticated
  using (true);

create policy "authenticated puede ver suscripciones"
  on push_subscriptions for select
  to authenticated
  using (true);
