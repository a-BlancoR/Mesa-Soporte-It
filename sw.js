// Service Worker de Mesa de Soporte IT
// Guarda en caché el "cascarón" de la app (HTML, manifest, íconos) para que
// abra rápido e instalada como app. Las llamadas a Supabase (otro dominio)
// NUNCA se cachean: siempre van directo a la red para no mostrar datos viejos.

const CACHE_NAME = 'mesa-soporte-v1';
const APP_SHELL = ['./Index.html', './manifest.json', './icon-192.png', './icon-512.png'];

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(CACHE_NAME).then((cache) => cache.addAll(APP_SHELL)));
  self.skipWaiting();
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k)))
    )
  );
  self.clients.claim();
});

self.addEventListener('fetch', (e) => {
  const url = new URL(e.request.url);

  // Cualquier cosa que no sea del mismo origen (Supabase, EmailJS, fuentes de Google)
  // se deja pasar sin tocarla: no queremos servir datos de tickets desde caché.
  if (url.origin !== self.location.origin) return;

  e.respondWith(
    caches.match(e.request).then((cached) => {
      const fetchPromise = fetch(e.request)
        .then((resp) => {
          const clone = resp.clone();
          caches.open(CACHE_NAME).then((cache) => cache.put(e.request, clone));
          return resp;
        })
        .catch(() => cached);
      return cached || fetchPromise;
    })
  );
});

// ---- Notificaciones push ----
// Llega incluso con la app cerrada o en segundo plano: el sistema operativo
// despierta este service worker solo para procesar el mensaje.
self.addEventListener('push', (e) => {
  let data = { title: 'Mesa de Soporte IT', body: 'Tienes una actualización', badgeCount: null };
  try { data = { ...data, ...e.data.json() }; } catch (err) { /* payload no era JSON, se usa el default */ }

  const options = {
    body: data.body,
    icon: 'icon-192.png',
    badge: 'icon-192.png',
    data: { ticketId: data.ticketId || null },
    vibrate: [120, 60, 120],
  };

  const tasks = [self.registration.showNotification(data.title, options)];

  // Actualiza el número visible sobre el ícono de la app (Badging API).
  if (typeof data.badgeCount === 'number' && 'setAppBadge' in self.navigator) {
    tasks.push(
      data.badgeCount > 0
        ? self.navigator.setAppBadge(data.badgeCount).catch(() => {})
        : self.navigator.clearAppBadge().catch(() => {})
    );
  }

  e.waitUntil(Promise.all(tasks));
});

// Al tocar la notificación, abre (o enfoca) la app.
self.addEventListener('notificationclick', (e) => {
  e.notification.close();
  e.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((clients) => {
      for (const client of clients) {
        if ('focus' in client) return client.focus();
      }
      if (self.clients.openWindow) return self.clients.openWindow('./index.html');
    })
  );
});
