-- =============================================================================
-- PASO 4 — El seguimiento acepta también el folio COMPLETO (TK-2026-0317)
-- Fecha: 29-oct-2026
--
-- Antes, buscar_tickets() solo entendía los últimos dígitos ("0317" o "317") o
-- el nombre completo; si alguien escribía el folio completo lo trataba como
-- nombre y no encontraba nada.
--
-- Ahora acepta:
--   * "TK-2026-0317", "tk-2026-317", "TK 2026 0317" (sin importar mayúsculas,
--     guiones/espacios ni ceros a la izquierda) → folio exacto, de cualquier año
--   * "0317" / "317" → folio del año actual (en enero también del anterior)
--   * nombre completo exacto (mín. 5 letras, sin importar mayúsculas/acentos)
-- Se puede ejecutar más de una vez.
-- =============================================================================

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
  m     text[];
  num   text;
begin
  -- 1) Folio completo: TK-AAAA-NNNN (acepta espacios o guiones, mayúsculas o no)
  m := regexp_match(upper(q), '^TK[\s-]*(\d{4})[\s-]*(\d{1,6})$');
  if m is not null then
    num := case when char_length(m[2]) < 4 then lpad(m[2], 4, '0') else m[2] end;
    return query
      select t.id, t.status, t.priority
      from public.tickets t
      where t.id = 'TK-' || m[1] || '-' || num;
    return;
  end if;

  -- 2) Solo los últimos dígitos (del año actual; en enero también del anterior)
  if q ~ '^\d{1,6}$' then
    num := case when char_length(q) < 4 then lpad(q, 4, '0') else q end;
    anios := array[extract(year from hoy)::int];
    if extract(month from hoy) = 1 then
      anios := anios || (extract(year from hoy)::int - 1);
    end if;
    return query
      select t.id, t.status, t.priority
      from public.tickets t
      where t.id = any (select 'TK-' || a || '-' || num from unnest(anios) as a)
      order by t.id desc;
    return;
  end if;

  -- 3) Nombre completo exacto
  if char_length(q) >= 5 then
    return query
      select t.id, t.status, t.priority
      from public.tickets t
      where translate(regexp_replace(lower(btrim(t.requester)), '\s+', ' ', 'g'), 'áéíóúüñ', 'aeiouun')
          = translate(regexp_replace(lower(q),                  '\s+', ' ', 'g'), 'áéíóúüñ', 'aeiouun')
      order by t.id desc
      limit 50;
  end if;
end;
$$;
revoke all on function public.buscar_tickets(text) from public;
grant execute on function public.buscar_tickets(text) to anon, authenticated;
