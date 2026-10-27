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

## Reglas de diseño importantes

- **Cada ticket guarda una copia** del departamento y puesto que tenía el solicitante el día
  que se creó. Cambiar a una persona de departamento (Catálogos → *Cambiar depto.*) solo
  afecta a sus tickets nuevos; el historial y las métricas pasadas no cambian.
- Al subir cambios a `sw.js`, aumentar el número de `CACHE_NAME` (`mesa-ayuda-v2` → `v3`…).
