// Service Worker de Mesa de Ayuda · Secretaría del Trabajo
//
// Qué hace:
//  - Guarda en caché el "cascarón" de la app (HTML, manifest, íconos) para que abra
//    aunque la red falle y se pueda instalar como app.
//  - Recibe las notificaciones push aunque la app esté cerrada.
//
// Estrategias de caché:
//  - Páginas HTML → "primero la red": siempre intenta bajar la versión más nueva y
//    solo usa la copia guardada si no hay internet. (Antes era "primero la caché",
//    por eso después de subir cambios a GitHub se veía la versión vieja hasta la
//    segunda vez que se abría la app.)
//  - Imágenes, manifest, etc. → "primero la caché": casi nunca cambian.
//  - Supabase, EmailJS y otros dominios → nunca se tocan: los datos de tickets
//    siempre vienen directo de la red.
//
// IMPORTANTE: cada vez que cambies este archivo, sube el número de CACHE_NAME
// para que los dispositivos borren la caché anterior.

const CACHE_NAME = 'mesa-ayuda-v2';
const APP_SHELL = ['./', './index.html', './manifest.json', './icon-192.png', './icon-512.png'];

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
  if (e.request.method !== 'GET') return;
  const url = new URL(e.request.url);
  if (url.origin !== self.location.origin) return;

  const guardar = (resp) => {
    if (resp && resp.ok) {
      const copia = resp.clone();
      caches.open(CACHE_NAME).then((cache) => cache.put(e.request, copia));
    }
    return resp;
  };

  // Navegación (abrir la página): primero la red, la caché solo como respaldo sin internet.
  if (e.request.mode === 'navigate') {
    e.respondWith(
      fetch(e.request)
        .then(guardar)
        .catch(() => caches.match(e.request).then((c) => c || caches.match('./index.html')))
    );
    return;
  }

  // Resto de archivos propios: primero la caché, y en segundo plano se actualiza.
  e.respondWith(
    caches.match(e.request).then((cached) => {
      const red = fetch(e.request).then(guardar).catch(() => cached);
      return cached || red;
    })
  );
});

// ---- Notificaciones push ----
// Llegan incluso con la app cerrada: el sistema operativo despierta este
// service worker solo para procesar el mensaje.
self.addEventListener('push', (e) => {
  let data = { title: 'Mesa de Ayuda', body: 'Tienes una actualización', badgeCount: null };
  try { data = { ...data, ...e.data.json() }; } catch (err) { /* payload no era JSON */ }

  const options = {
    body: data.body,
    icon: 'icon-192.png',
    badge: 'icon-192.png',
    data: { ticketId: data.ticketId || null },
    vibrate: [120, 60, 120],
  };

  const tasks = [self.registration.showNotification(data.title, options)];

  // Número sobre el ícono de la app (Badging API).
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
