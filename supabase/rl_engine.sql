-- ===== Faz 2c: ortak rulet masası (sunucu taraflı) =====
-- Tek ortak masa. Bahisler, sonuç ve ödemeler burada; istemciler yalnız bahis/çevir gönderir ve
-- rl_table.state değişikliklerini Realtime ile alır. Tekrar çalıştırmak güvenlidir.
-- Şimşek modu (state.light, varsayılan açık): her turda 1–5 sayıya 50x–500x çarpan düşer (state.lightning);
-- sayı bahsi 29:1 öder, şimşek sayısı çarpanını öder; diğer bahisler değişmez.

create table if not exists public.rl_table (
  id int primary key default 1 check (id = 1),
  state jsonb not null default '{}'::jsonb,
  version bigint not null default 0,
  updated_at timestamptz not null default now()
);
insert into public.rl_table (id) values (1) on conflict (id) do nothing;
alter table public.rl_table enable row level security;
drop policy if exists "rl_table: herkes okur" on public.rl_table;
create policy "rl_table: herkes okur" on public.rl_table for select to authenticated using (true);

create or replace function public.rl_empty_state() returns jsonb language sql immutable as $$
  select jsonb_build_object('phase','bet','round',0,'deadline',null,'bets','[]'::jsonb,'result',null,'spin_at',null,'results',null,'history','[]'::jsonb,'light',true,'lightning',null)
$$;

-- bahis anahtarı geçerli mi
create or replace function public.rl_valid_key(k text) returns boolean language plpgsql immutable as $$
declare parts text[]; i int; n int;
begin
  if k in ('red','black','odd','even','low','high','d1','d2','d3','c1','c2','c3') then return true; end if;
  if k ~ '^n:(0|[1-9]|[12][0-9]|3[0-6])$' then return true; end if;
  if k ~ '^sp:[0-9]+-[0-9]+$' or k ~ '^co:[0-9]+-[0-9]+-[0-9]+-[0-9]+$' then
    parts := string_to_array(split_part(k, ':', 2), '-');
    foreach i in array parts::int[] loop if i < 0 or i > 36 then return false; end if; end loop;
    if k like 'sp:%' then
      if parts[1]::int = 0 then return parts[2]::int between 1 and 3; end if;
      n := parts[2]::int - parts[1]::int;
      return (n = 1 and (parts[1]::int % 3) <> 0) or n = 3;
    else
      n := parts[1]::int;
      return (n % 3) <> 0 and n between 1 and 33 and parts[2]::int = n+1 and parts[3]::int = n+3 and parts[4]::int = n+4;
    end if;
  end if;
  return false;
end $$;

create or replace function public.rl_mult(k text) returns int language sql immutable as $$
  select case when k like 'n:%' then 36 when k like 'sp:%' then 18 when k like 'co:%' then 9 when k ~ '^[dc][123]$' then 3 else 2 end
$$;

-- şimşek çekilişi: 1–5 sayı (ağırlık 15/30/30/15/10), çarpan 50/100/200/300/400/500 (ağırlık 55/24/11/6/3/1)
create or replace function public.rl_lightning() returns jsonb language plpgsql as $$
declare cnt int; r numeric; n int; m int; res jsonb := '{}'::jsonb; i int := 0;
begin
  r := random()*100; cnt := case when r < 15 then 1 when r < 45 then 2 when r < 75 then 3 when r < 90 then 4 else 5 end;
  while i < cnt loop
    n := floor(random()*37)::int; if n > 36 then n := 36; end if;
    if res ? n::text then continue; end if;
    r := random()*100; m := case when r < 55 then 50 when r < 79 then 100 when r < 90 then 200 when r < 96 then 300 when r < 99 then 400 else 500 end;
    res := res || jsonb_build_object(n::text, m); i := i + 1;
  end loop;
  return res;
end $$;

-- ödeme katı: şimşek modunda sayı bahsi 30 (29:1), şimşek sayısı çarpan+1; diğerleri rl_mult
create or replace function public.rl_pay(k text, n int, light boolean, lt jsonb) returns int language plpgsql immutable as $$
begin
  if k like 'n:%' then
    if not coalesce(light, true) then return 36; end if;
    if lt is not null and lt ? split_part(k, ':', 2) then return (lt ->> split_part(k, ':', 2))::int + 1; end if;
    return 30;
  end if;
  return public.rl_mult(k);
end $$;

create or replace function public.rl_wins(k text, n int) returns boolean language plpgsql immutable as $$
declare reds int[] := array[1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36];
begin
  if k like 'n:%' then return split_part(k,':',2)::int = n; end if;
  if k like 'sp:%' or k like 'co:%' then return n = any (string_to_array(split_part(k,':',2),'-')::int[]); end if;
  if n = 0 then return false; end if;
  return case k
    when 'red' then n = any(reds) when 'black' then not (n = any(reds))
    when 'odd' then n % 2 = 1 when 'even' then n % 2 = 0
    when 'low' then n <= 18 when 'high' then n >= 19
    when 'd1' then n <= 12 when 'd2' then n between 13 and 24 when 'd3' then n >= 25
    when 'c1' then n % 3 = 1 when 'c2' then n % 3 = 2 when 'c3' then n % 3 = 0
    else false end;
end $$;

create or replace function public.rl_save(st jsonb) returns void language sql as $$
  update public.rl_table set state = st, version = version + 1, updated_at = now() where id = 1
$$;

create or replace function public.rl_seated(uid uuid) returns boolean language sql stable as $$
  select exists (select 1 from public.seats where game = 'rl' and user_id = uid)
$$;

-- bahis koy (aynı anahtara tekrar koyunca birikir). İlk bahisle 15 sn geri sayım başlar
create or replace function public.rl_bet(p_key text, p_amount numeric) returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); st jsonb; bets jsonb; i int; found boolean := false; nm text; b jsonb;
begin
  if uid is null then raise exception 'oturum yok'; end if;
  if p_amount <= 0 or not public.rl_valid_key(p_key) then raise exception 'geçersiz bahis'; end if;
  if not public.rl_seated(uid) then raise exception 'Önce bir sandalyeye otur'; end if;
  select state into st from public.rl_table where id = 1 for update;
  if st = '{}'::jsonb then st := public.rl_empty_state(); end if;
  if st->>'phase' <> 'bet' then raise exception 'Çark dönüyor'; end if;
  perform public.bj_charge(uid, p_amount);
  select name into nm from public.profiles where id = uid;
  bets := st->'bets';
  for i in 0..coalesce(jsonb_array_length(bets),0)-1 loop
    b := bets->i;
    if (b->>'user')::uuid = uid and b->>'key' = p_key then
      bets := jsonb_set(bets, array[i::text,'amt'], to_jsonb((b->>'amt')::numeric + p_amount)); found := true;
    end if;
  end loop;
  if not found then bets := bets || jsonb_build_object('user', uid::text, 'name', coalesce(nm,'Oyuncu'), 'key', p_key, 'amt', p_amount); end if;
  st := jsonb_set(st, '{bets}', bets);
  if st->>'deadline' is null then st := jsonb_set(st, '{deadline}', to_jsonb(now() + interval '15 seconds')); end if;
  perform public.rl_save(st);
  return st;
end $$;
grant execute on function public.rl_bet(text, numeric) to authenticated;

-- kendi bahislerini geri al
create or replace function public.rl_unbet() returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); st jsonb; b jsonb; keep jsonb := '[]'::jsonb; refund numeric := 0;
begin
  if uid is null then raise exception 'oturum yok'; end if;
  select state into st from public.rl_table where id = 1 for update;
  if st->>'phase' <> 'bet' then raise exception 'Çark dönüyor'; end if;
  for b in select * from jsonb_array_elements(st->'bets') loop
    if (b->>'user')::uuid = uid then refund := refund + (b->>'amt')::numeric; else keep := keep || b; end if;
  end loop;
  if refund > 0 then perform public.bj_pay(uid, refund); end if;
  st := jsonb_set(st, '{bets}', keep);
  if jsonb_array_length(keep) = 0 then st := jsonb_set(st, '{deadline}', 'null'); end if;
  perform public.rl_save(st);
  return st;
end $$;
grant execute on function public.rl_unbet() to authenticated;

-- kendi bahislerini ikiye katla
create or replace function public.rl_double() returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); st jsonb; b jsonb; outb jsonb := '[]'::jsonb; need numeric := 0;
begin
  if uid is null then raise exception 'oturum yok'; end if;
  select state into st from public.rl_table where id = 1 for update;
  if st->>'phase' <> 'bet' then raise exception 'Çark dönüyor'; end if;
  for b in select * from jsonb_array_elements(st->'bets') loop
    if (b->>'user')::uuid = uid then need := need + (b->>'amt')::numeric; end if;
  end loop;
  if need = 0 then raise exception 'Masada bahsin yok'; end if;
  perform public.bj_charge(uid, need);
  for b in select * from jsonb_array_elements(st->'bets') loop
    if (b->>'user')::uuid = uid then outb := outb || jsonb_set(b, '{amt}', to_jsonb((b->>'amt')::numeric * 2)); else outb := outb || b; end if;
  end loop;
  st := jsonb_set(st, '{bets}', outb);
  perform public.rl_save(st);
  return st;
end $$;
grant execute on function public.rl_double() to authenticated;

-- çevir: sonuç üret, öde, çark aşamasına geç (istemciler aynı sonuca döner)
create or replace function public.rl_spin_internal(st jsonb) returns jsonb language plpgsql as $$
declare n int; b jsonb; u uuid; tot numeric; ret numeric; res jsonb := '[]'::jsonb; hist jsonb; r record; light boolean; lt jsonb;
begin
  if coalesce(jsonb_array_length(st->'bets'),0) = 0 then raise exception 'Masada bahis yok'; end if;
  n := floor(random() * 37)::int; if n > 36 then n := 36; end if;
  light := coalesce((st->>'light')::boolean, true);
  lt := case when light then public.rl_lightning() else null end;
  for r in select (e->>'user')::uuid as usr, max(e->>'name') as nm,
                  sum((e->>'amt')::numeric) as t,
                  sum(case when public.rl_wins(e->>'key', n) then (e->>'amt')::numeric * public.rl_pay(e->>'key', n, light, lt) else 0 end) as w
             from jsonb_array_elements(st->'bets') e group by 1 loop
    if r.w > 0 then perform public.bj_pay(r.usr, r.w); end if;
    res := res || jsonb_build_object('user', r.usr::text, 'name', r.nm, 'bet', round(r.t,2), 'won', round(r.w,2), 'net', round(r.w - r.t, 2));
  end loop;
  hist := coalesce(st->'history', '[]'::jsonb);
  hist := to_jsonb(n) || hist; if jsonb_array_length(hist) > 20 then hist := (select jsonb_agg(x) from (select x from jsonb_array_elements(hist) with ordinality as t(x, o) where o <= 20 order by o) q); end if;
  st := jsonb_set(st, '{phase}', '"spin"');
  st := jsonb_set(st, '{round}', to_jsonb(coalesce((st->>'round')::int,0) + 1));
  st := jsonb_set(st, '{result}', to_jsonb(n));
  st := jsonb_set(st, '{results}', res);
  st := jsonb_set(st, '{history}', hist);
  st := jsonb_set(st, '{lightning}', coalesce(lt, 'null'::jsonb));
  st := jsonb_set(st, '{spin_at}', to_jsonb(now()));
  st := jsonb_set(st, '{deadline}', to_jsonb(now() + case when light then interval '17 seconds' else interval '14 seconds' end));
  return st;
end $$;

create or replace function public.rl_spin() returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); st jsonb; mine boolean := false; b jsonb;
begin
  if uid is null then raise exception 'oturum yok'; end if;
  select state into st from public.rl_table where id = 1 for update;
  if st = '{}'::jsonb then st := public.rl_empty_state(); end if;
  if st->>'phase' <> 'bet' then raise exception 'Çark zaten dönüyor'; end if;
  for b in select * from jsonb_array_elements(st->'bets') loop if (b->>'user')::uuid = uid then mine := true; end if; end loop;
  if not mine then raise exception 'Önce bahis koy'; end if;
  st := public.rl_spin_internal(st);
  perform public.rl_save(st);
  return st;
end $$;
grant execute on function public.rl_spin() to authenticated;

-- zaman aşımı: bahis süresi dolunca çevir; çark+sonuç süresi dolunca yeni tur
create or replace function public.rl_tick() returns jsonb
language plpgsql security definer set search_path = public as $$
declare st jsonb; dl timestamptz;
begin
  if auth.uid() is null then raise exception 'oturum yok'; end if;
  select state into st from public.rl_table where id = 1 for update;
  if st = '{}'::jsonb then st := public.rl_empty_state(); perform public.rl_save(st); return st; end if;
  dl := (st->>'deadline')::timestamptz;
  if dl is null or dl > now() then return st; end if;
  if st->>'phase' = 'bet' then
    if coalesce(jsonb_array_length(st->'bets'),0) > 0 then st := public.rl_spin_internal(st); else st := jsonb_set(st, '{deadline}', 'null'); end if;
  else
    st := jsonb_set(st, '{phase}', '"bet"');
    st := jsonb_set(st, '{bets}', '[]');
    st := jsonb_set(st, '{deadline}', 'null');
    st := jsonb_set(st, '{results}', 'null');
    st := jsonb_set(st, '{result}', 'null');
    st := jsonb_set(st, '{spin_at}', 'null');
    st := jsonb_set(st, '{lightning}', 'null');
  end if;
  perform public.rl_save(st);
  return st;
end $$;
grant execute on function public.rl_tick() to authenticated;

-- şimşek modunu aç/kapat: oturan oyuncu, bahis aşamasında ve masada bahis yokken
create or replace function public.rl_light(p_on boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); st jsonb;
begin
  if uid is null then raise exception 'oturum yok'; end if;
  if not public.rl_seated(uid) then raise exception 'Önce bir sandalyeye otur'; end if;
  select state into st from public.rl_table where id = 1 for update;
  if st = '{}'::jsonb then st := public.rl_empty_state(); end if;
  if st->>'phase' <> 'bet' then raise exception 'Çark dönüyor'; end if;
  if coalesce(jsonb_array_length(st->'bets'),0) > 0 then raise exception 'Masada bahis varken mod değişmez'; end if;
  st := jsonb_set(st, '{light}', to_jsonb(coalesce(p_on, true)));
  perform public.rl_save(st);
  return st;
end $$;
grant execute on function public.rl_light(boolean) to authenticated;

do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='rl_table') then
    alter publication supabase_realtime add table public.rl_table;
  end if;
end $$;

update public.rl_table set state = public.rl_empty_state() where id = 1 and state = '{}'::jsonb;
