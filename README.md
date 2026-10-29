# Mesa de Ayuda · Secretaría del Trabajo de Sonora

Sistema de tickets de soporte técnico del área de Informática. Página web instalable
como app (PWA), con base de datos en Supabase y notificaciones push.

## Archivos del repositorio

| Archivo | Para qué sirve |
|---|---|
| `index.html` | La aplicación completa: formulario público, seguimiento de tickets y panel de administrador. |
| `sw.js` | Service worker: caché para abrir sin red y recepción de notificaciones push. |
| `manifest.json` | Datos para instalar la app en el celular o la PC (nombre, colores, íconos). |
| `icon-192.png`, `icon-512.png` | Íconos de la app. |
| `LOGO ST Blanco.png`, `patron-fondo.png` | Logo y patrón del encabezado institucional. |
| `supabase/functions/send-push/index.ts` | Función de Supabase que envía las notificaciones push al crear o actualizar un ticket. No corre en GitHub Pages: se despliega en Supabase. |
| `sql/sql-push-subscriptions.sql` | Script (ya ejecutado) que creó la tabla de suscripciones push. Se guarda como referencia. |
| `sql/sql-push-subscriptions-authenticated.sql` | Script (ya ejecutado) con los permisos para el administrador con sesión iniciada. |
| `sql/2026-10-29-paso1-endurecer-rls.sql` | Seguridad: solo las cuentas de la tabla `admins` administran; el público solo crea tickets "Abierto/Media", lee catálogos y busca con `buscar_tickets()`. |
| `sql/2026-10-29-paso2-quitar-ticket-lookup.sql` | Elimina la vista `ticket_lookup`. Ejecutar **después** de publicar el `index.html` que usa `buscar_tickets()`. |
| `sql/2026-10-29-paso4-buscar-folio-completo.sql` | El seguimiento acepta el folio completo (`TK-2026-0317`), los últimos dígitos o el nombre completo. |
| `sql/2026-10-29-paso5-anti-bots.sql` | Límites de frecuencia para el público (tickets, catálogos, búsquedas), campo trampa y tiempo mínimo de llenado, y tabla `registro_actividad` (IP y navegador de cada ticket, solo admins). |
| `sql/2026-10-29-paso3-folios-automaticos.sql` | El folio lo asigna la base de datos al guardar (trigger `asignar_folio`), saltando folios ya ocupados. El formulario público usa `crear_ticket()`. |

## Administradores

Iniciar sesión **no basta** para administrar: la cuenta debe estar en la tabla `admins`.
Para dar de alta una cuenta nueva (después de crearla en Authentication → Users):

```sql
insert into public.admins (user_id, nota)
select id, email from auth.users where email = 'correo@ejemplo.com';
```

## Reglas de diseño importantes

- **Cada ticket guarda una copia** del departamento y puesto que tenía el solicitante el día
  que se creó. Cambiar a una persona de departamento (Catálogos → *Cambiar depto.*) solo
  afecta a sus tickets nuevos; el historial y las métricas pasadas no cambian.
- **El folio lo pone la base de datos**, nunca la app: `TK-<año de registro>-<número>`, con un
  contador continuo que salta los folios que ya existan. Editar fechas de un ticket no cambia su folio.
- Al subir cambios a `sw.js`, aumentar el número de `CACHE_NAME` (`mesa-ayuda-v3` → `v4`…).
- Al publicar cambios en `index.html`, subir `APP_VERSION` (p. ej. `2026-10-29.4` → `2026-11-02.1`).
  Las pestañas y apps instaladas que sigan abiertas mostrarán el botón *"Hay una versión nueva"*.
