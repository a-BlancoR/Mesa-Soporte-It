// supabase/functions/send-push/index.ts
//
// Esta función se dispara automáticamente por un Database Webhook cuando se
// inserta o actualiza una fila en "tickets". Envía una notificación push a
// todos los dispositivos suscritos (o solo al técnico asignado, si aplica),
// e incluye el número de tickets abiertos para que el celular actualice el
// badge del ícono.

import webpush from "npm:web-push@3.6.7";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const VAPID_PUBLIC_KEY = Deno.env.get("VAPID_PUBLIC_KEY")!;
const VAPID_PRIVATE_KEY = Deno.env.get("VAPID_PRIVATE_KEY")!;

webpush.setVapidDetails(
  "mailto:mesadeayuda.st@sonora.gob.mx",
  VAPID_PUBLIC_KEY,
  VAPID_PRIVATE_KEY
);

async function sbFetch(path: string, init?: RequestInit) {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
    ...init,
    headers: {
      "Content-Type": "application/json",
      apikey: SERVICE_ROLE_KEY,
      Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
      ...(init?.headers || {}),
    },
  });
  if (!r.ok) throw new Error(await r.text());
  return r.json();
}

Deno.serve(async (req) => {
  try {
    const payload = await req.json();
    // El webhook de Supabase manda { type: "INSERT" | "UPDATE", table, record, old_record }
    const ticket = payload.record;
    const isNew = payload.type === "INSERT";

    // Cuenta de tickets abiertos/en proceso, para el badge del ícono.
    const open = await sbFetch(
      "tickets?select=id&status=in.(Abierto,En%20proceso)"
    );
    const badgeCount = Array.isArray(open) ? open.length : 0;

    const title = isNew ? "Nuevo ticket" : "Ticket actualizado";
    const body = isNew
      ? `${ticket.id} — ${ticket.requester} (${ticket.priority})`
      : `${ticket.id} ahora está: ${ticket.status}`;

    // Mismo criterio que ya usaba el filtro de identidad en el cliente:
    // - Suscripciones sin identidad elegida (technician null) reciben todo.
    // - Un ticket sin técnico asignado le avisa a todos.
    // - Un ticket ya asignado solo le avisa a ese técnico.
    const allSubs = await sbFetch("push_subscriptions?select=*");
    const subs = allSubs.filter(
      (s: any) => !s.technician || !ticket.technician || s.technician === ticket.technician
    );

    const results = await Promise.allSettled(
      subs.map((s: any) =>
        webpush.sendNotification(
          {
            endpoint: s.endpoint,
            keys: { p256dh: s.p256dh, auth: s.auth },
          },
          JSON.stringify({ title, body, badgeCount, ticketId: ticket.id })
        )
      )
    );

    // Limpia suscripciones que ya no existen (el usuario desinstaló la app,
    // borró datos del navegador, etc.) para no seguir intentando enviarles.
    const dead = subs.filter(
      (_: any, i: number) =>
        results[i].status === "rejected" &&
        [404, 410].includes((results[i] as any).reason?.statusCode)
    );
    for (const d of dead) {
      await sbFetch(`push_subscriptions?endpoint=eq.${encodeURIComponent(d.endpoint)}`, {
        method: "DELETE",
      });
    }

    return new Response(
      JSON.stringify({ sent: results.length, badgeCount }),
      { headers: { "Content-Type": "application/json" } }
    );
  } catch (err) {
    console.error(err);
    return new Response(JSON.stringify({ error: String(err) }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
});
