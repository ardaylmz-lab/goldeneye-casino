-- ===== Faz 2b: ortak blackjack motoru (sunucu taraflı) =====
-- Tek ortak masa. Oyun mantığı burada çalışır; istemciler yalnız hamle gönderir ve
-- bj_table.state değişikliklerini Realtime ile alır. Deste ve kapalı kart bj_secret'ta durur (okunamaz).
-- Tekrar çalıştırmak güvenlidir.

create table if not exists public.bj_table (
  id int primary key default 1 check (id = 1),
  state jsonb not null default '{}'::jsonb,
  version bigint not null default 0,
  updated_at timestamptz not null default now()
);
create table if not exists public.bj_secret (
  id int primary key default 1 check (id = 1),
  deck text[] not null default '{}',
  hole text
);
insert into public.bj_table (id) values (1) on conflict (id) do nothing;
insert into public.bj_secret (id) values (1) on conflict (id) do nothing;

alter table public.bj_table enable row level security;
alter table public.bj_secret enable row level security;   -- politika yok: yalnız definer fonksiyonlar erişir
drop policy if exists "bj_table: herkes okur" on public.bj_table;
create policy "bj_table: herkes okur" on public.bj_table for select to authenticated using (true);

-- ---------- yardımcılar ----------
create or replace function public.bj_empty_state() returns jsonb language sql immutable as $$
  select jsonb_build_object(
    'phase','bet','round',0,'dealer','[]'::jsonb,'cur',null,'deadline',null,'results',null,'ins_pending','[]'::jsonb,
    'spots',(select jsonb_agg(jsonb_build_object('bet',0,'owner',null,'name',null,'ins',0,'hands','[]'::jsonb)) from generate_series(1,6)))
$$;

create or replace function public.bj_rank(c text) returns text language sql immutable as $$ select left(c, length(c)-1) $$;

create or replace function public.bj_val(cards jsonb) returns int language plpgsql immutable as $$
declare c text; r text; t int := 0; a int := 0;
begin
  for c in select jsonb_array_elements_text(cards) loop
    r := public.bj_rank(c);
    if r = 'A' then t := t + 11; a := a + 1;
    elsif r in ('10','J','Q','K') then t := t + 10;
    else t := t + r::int; end if;
  end loop;
  while t > 21 and a > 0 loop t := t - 10; a := a - 1; end loop;
  return t;
end $$;

create or replace function public.bj_new_deck() returns text[] language sql volatile as $$
  select array_agg(c order by random()) from (
    select r || s as c from unnest(array['A','2','3','4','5','6','7','8','9','10','J','Q','K']) r, unnest(array['♠','♥','♦','♣']) s) d
$$;

-- desteden bir kart çek (15'in altına inince yeni deste)
create or replace function public.bj_draw() returns text language plpgsql as $$
declare d text[]; c text;
begin
  select deck into d from public.bj_secret where id = 1 for update;
  if coalesce(cardinality(d),0) < 15 then d := public.bj_new_deck(); end if;
  c := d[1]; d := d[2:];
  update public.bj_secret set deck = d where id = 1;
  return c;
end $$;

create or replace function public.bj_save(st jsonb) returns void language sql as $$
  update public.bj_table set state = st, version = version + 1, updated_at = now() where id = 1
$$;

create or replace function public.bj_pay(uid uuid, amt numeric) returns void language sql as $$
  update public.profiles set balance = round(balance + amt, 2), updated_at = now() where id = uid
$$;

-- bakiyeden düş; yetmiyorsa hata
create or replace function public.bj_charge(uid uuid, amt numeric) returns void language plpgsql as $$
declare ok int;
begin
  update public.profiles set balance = round(balance - amt, 2), updated_at = now() where id = uid and balance >= amt;
  get diagnostics ok = row_count;
  if ok = 0 then raise exception 'Yetersiz bakiye'; end if;
end $$;

create or replace function public.bj_seated(uid uuid) returns boolean language sql stable as $$
  select exists (select 1 from public.seats where game = 'bj' and user_id = uid)
$$;

-- sıradaki bitmemiş el: {s,h} veya null
create or replace function public.bj_next_hand(st jsonb) returns jsonb language plpgsql immutable as $$
declare s int; h int; hs jsonb;
begin
  for s in 0..5 loop
    hs := st->'spots'->s->'hands';
    for h in 0..coalesce(jsonb_array_length(hs),0)-1 loop
      if not coalesce((hs->h->>'done')::boolean, false) then return jsonb_build_object('s',s,'h',h); end if;
    end loop;
  end loop;
  return null;
end $$;

create or replace function public.bj_reset_round(st jsonb) returns jsonb language plpgsql as $$
declare s int;
begin
  st := jsonb_set(st, '{phase}', '"bet"');
  st := jsonb_set(st, '{dealer}', '[]');
  st := jsonb_set(st, '{cur}', 'null');
  st := jsonb_set(st, '{deadline}', 'null');
  st := jsonb_set(st, '{results}', 'null');
  st := jsonb_set(st, '{ins_pending}', '[]');
  for s in 0..5 loop
    st := jsonb_set(st, array['spots', s::text], jsonb_build_object('bet',0,'owner',null,'name',null,'ins',0,'hands','[]'::jsonb));
  end loop;
  update public.bj_secret set hole = null where id = 1;
  return st;
end $$;

-- ---------- krupiye ve ödeme ----------
create or replace function public.bj_finish(st jsonb) returns jsonb language plpgsql as $$
declare hc text; dealer jsonb; d int; dbj boolean; s int; h int; hs jsonb; hd jsonb; p int; r numeric; bet numeric;
        owner uuid; sn numeric; win boolean; anylive boolean := false; results jsonb := '[]'::jsonb; insv numeric; insd numeric;
begin
  select bj_secret.hole into hc from public.bj_secret where id = 1;
  dealer := jsonb_build_array(st->'dealer'->>0, hc);
  dbj := jsonb_array_length(dealer) = 2 and public.bj_val(dealer) = 21;
  -- yaşayan el var mı (21'i geçmemiş, blackjack olmayan)
  for s in 0..5 loop
    hs := st->'spots'->s->'hands';
    for h in 0..coalesce(jsonb_array_length(hs),0)-1 loop
      if public.bj_val(hs->h->'cards') <= 21 and not coalesce((hs->h->>'bj')::boolean,false) then anylive := true; end if;
    end loop;
  end loop;
  if anylive and not dbj then
    while public.bj_val(dealer) < 17 loop dealer := dealer || to_jsonb(public.bj_draw()); end loop;
  end if;
  d := public.bj_val(dealer);
  -- ödemeler
  for s in 0..5 loop
    hs := st->'spots'->s->'hands';
    if coalesce(jsonb_array_length(hs),0) = 0 then continue; end if;
    owner := (st->'spots'->s->>'owner')::uuid; sn := 0; win := false;
    for h in 0..jsonb_array_length(hs)-1 loop
      hd := hs->h; p := public.bj_val(hd->'cards'); bet := (hd->>'bet')::numeric; r := 0;
      if coalesce((hd->>'bj')::boolean,false) then r := case when dbj then bet else bet * 2.5 end; if not dbj then win := true; end if;
      elsif p > 21 or dbj then r := 0;
      elsif d > 21 or p > d then r := bet * 2;
      elsif p = d then r := bet; end if;
      if r > 0 then perform public.bj_pay(owner, r); end if;
      sn := sn + r - bet;
    end loop;
    insv := coalesce((st->'spots'->s->>'ins')::numeric, 0); insd := 0;
    if insv > 0 then
      if dbj then perform public.bj_pay(owner, insv * 3); insd := insv * 2; else insd := -insv; end if;
      sn := sn + insd;
    end if;
    results := results || jsonb_build_object('spot', s, 'owner', owner, 'net', round(sn,2), 'ins', round(insd,2), 'bj', win);
  end loop;
  st := jsonb_set(st, '{dealer}', dealer);
  st := jsonb_set(st, '{phase}', '"settle"');
  st := jsonb_set(st, '{cur}', 'null');
  st := jsonb_set(st, '{results}', results);
  st := jsonb_set(st, '{dealer_bj}', to_jsonb(dbj));
  st := jsonb_set(st, '{deadline}', to_jsonb(now() + interval '9 seconds'));
  return st;
end $$;

-- sıradaki ele geç; el kalmadıysa krupiye oynar
create or replace function public.bj_advance(st jsonb) returns jsonb language plpgsql as $$
declare nx jsonb;
begin
  nx := public.bj_next_hand(st);
  if nx is null then return public.bj_finish(st); end if;
  st := jsonb_set(st, '{cur}', nx);
  st := jsonb_set(st, '{phase}', '"play"');
  st := jsonb_set(st, '{deadline}', to_jsonb(now() + interval '25 seconds'));
  return st;
end $$;

-- sigorta kararları tamamlanınca
create or replace function public.bj_after_insurance(st jsonb) returns jsonb language plpgsql as $$
declare hc text; s int;
begin
  select bj_secret.hole into hc from public.bj_secret where id = 1;
  st := jsonb_set(st, '{ins_pending}', '[]');
  if public.bj_val(jsonb_build_array(st->'dealer'->>0, hc)) = 21 then return public.bj_finish(st); end if;
  -- sigorta kaybedildi: hemen düş (bakiye zaten alınmıştı), kayıt kalsın (settle'da -sig gösterilir)
  return public.bj_advance(st);
end $$;

-- ---------- oyuncu çağrıları ----------
create or replace function public.bj_bet(p_spot int, p_amount numeric) returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); st jsonb; sp jsonb; cnt int; nm text; i int;
begin
  if uid is null then raise exception 'oturum yok'; end if;
  if p_spot < 0 or p_spot > 5 or p_amount <= 0 then raise exception 'geçersiz bahis'; end if;
  if not public.bj_seated(uid) then raise exception 'Önce bir sandalyeye otur'; end if;
  select state into st from public.bj_table where id = 1 for update;
  if st = '{}'::jsonb then st := public.bj_empty_state(); end if;
  if st->>'phase' = 'settle' then st := public.bj_reset_round(st); end if;
  if st->>'phase' <> 'bet' then raise exception 'El sürüyor'; end if;
  sp := st->'spots'->p_spot;
  if sp->>'owner' is not null and (sp->>'owner')::uuid <> uid then raise exception 'Bu yere % oynuyor', sp->>'name'; end if;
  if sp->>'owner' is null then
    cnt := 0;
    for i in 0..5 loop if (st->'spots'->i->>'owner')::uuid = uid then cnt := cnt + 1; end if; end loop;
    if cnt >= 2 then raise exception 'En fazla iki yere oynayabilirsin'; end if;
  end if;
  perform public.bj_charge(uid, p_amount);
  select name into nm from public.profiles where id = uid;
  sp := jsonb_set(sp, '{bet}', to_jsonb(coalesce((sp->>'bet')::numeric,0) + p_amount));
  sp := jsonb_set(sp, '{owner}', to_jsonb(uid::text));
  sp := jsonb_set(sp, '{name}', to_jsonb(coalesce(nm,'Oyuncu')));
  st := jsonb_set(st, array['spots', p_spot::text], sp);
  if st->>'deadline' is null then st := jsonb_set(st, '{deadline}', to_jsonb(now() + interval '10 seconds')); end if;
  perform public.bj_save(st);
  return st;
end $$;
grant execute on function public.bj_bet(int, numeric) to authenticated;

-- kendi bahislerini geri al
create or replace function public.bj_unbet() returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); st jsonb; i int; b numeric; any_left boolean := false;
begin
  if uid is null then raise exception 'oturum yok'; end if;
  select state into st from public.bj_table where id = 1 for update;
  if st->>'phase' <> 'bet' then raise exception 'El sürüyor'; end if;
  for i in 0..5 loop
    if (st->'spots'->i->>'owner')::uuid = uid then
      b := coalesce((st->'spots'->i->>'bet')::numeric,0);
      if b > 0 then perform public.bj_pay(uid, b); end if;
      st := jsonb_set(st, array['spots', i::text], jsonb_build_object('bet',0,'owner',null,'name',null,'ins',0,'hands','[]'::jsonb));
    elsif coalesce((st->'spots'->i->>'bet')::numeric,0) > 0 then any_left := true; end if;
  end loop;
  if not any_left then st := jsonb_set(st, '{deadline}', 'null'); end if;
  perform public.bj_save(st);
  return st;
end $$;
grant execute on function public.bj_unbet() to authenticated;

-- dağıt (bahsi olan herhangi bir oyuncu ya da zaman dolunca bj_tick)
create or replace function public.bj_deal_internal(st jsonb) returns jsonb language plpgsql as $$
declare i int; r int; sp jsonb; hd jsonb; up text; hc text; anybet boolean := false; pend jsonb := '[]'::jsonb; o text;
begin
  update public.bj_secret set deck = public.bj_new_deck() where id = 1;
  for i in 0..5 loop
    sp := st->'spots'->i;
    if coalesce((sp->>'bet')::numeric,0) > 0 then
      anybet := true;
      hd := jsonb_build_object('cards','[]'::jsonb,'bet',(sp->>'bet')::numeric,'done',false,'dbl',false,'split',false,'bj',false);
      st := jsonb_set(st, array['spots', i::text, 'hands'], jsonb_build_array(hd));
    else
      st := jsonb_set(st, array['spots', i::text], jsonb_build_object('bet',0,'owner',null,'name',null,'ins',0,'hands','[]'::jsonb));
    end if;
  end loop;
  if not anybet then raise exception 'Masada bahis yok'; end if;
  for r in 1..2 loop
    for i in 0..5 loop
      if jsonb_array_length(st->'spots'->i->'hands') > 0 then
        st := jsonb_set(st, array['spots', i::text, 'hands','0','cards'], (st->'spots'->i->'hands'->0->'cards') || to_jsonb(public.bj_draw()));
      end if;
    end loop;
    if r = 1 then up := public.bj_draw(); else hc := public.bj_draw(); end if;
  end loop;
  update public.bj_secret set hole = hc where id = 1;
  st := jsonb_set(st, '{dealer}', jsonb_build_array(up, '??'));
  st := jsonb_set(st, '{round}', to_jsonb(coalesce((st->>'round')::int,0) + 1));
  st := jsonb_set(st, '{results}', 'null');
  st := jsonb_set(st, '{dealer_bj}', 'false');
  -- blackjack'ler
  for i in 0..5 loop
    if jsonb_array_length(st->'spots'->i->'hands') > 0 and public.bj_val(st->'spots'->i->'hands'->0->'cards') = 21 then
      st := jsonb_set(st, array['spots', i::text, 'hands','0','bj'], 'true');
      st := jsonb_set(st, array['spots', i::text, 'hands','0','done'], 'true');
    end if;
  end loop;
  if public.bj_rank(up) = 'A' then
    for i in 0..5 loop
      o := st->'spots'->i->>'owner';
      if o is not null and not (pend ? o) then pend := pend || to_jsonb(o); end if;
    end loop;
    st := jsonb_set(st, '{phase}', '"insure"');
    st := jsonb_set(st, '{ins_pending}', pend);
    st := jsonb_set(st, '{deadline}', to_jsonb(now() + interval '12 seconds'));
    return st;
  end if;
  if public.bj_val(jsonb_build_array(up, hc)) = 21 then return public.bj_finish(st); end if;
  return public.bj_advance(st);
end $$;

create or replace function public.bj_deal() returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); st jsonb; i int; mine boolean := false;
begin
  if uid is null then raise exception 'oturum yok'; end if;
  select state into st from public.bj_table where id = 1 for update;
  if st->>'phase' <> 'bet' then raise exception 'El zaten başladı'; end if;
  for i in 0..5 loop if (st->'spots'->i->>'owner')::uuid = uid then mine := true; end if; end loop;
  if not mine then raise exception 'Önce bahis koy'; end if;
  st := public.bj_deal_internal(st);
  perform public.bj_save(st);
  return st;
end $$;
grant execute on function public.bj_deal() to authenticated;

create or replace function public.bj_insure(p_take boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); st jsonb; i int; need numeric := 0; pend jsonb;
begin
  if uid is null then raise exception 'oturum yok'; end if;
  select state into st from public.bj_table where id = 1 for update;
  if st->>'phase' <> 'insure' then raise exception 'Sigorta aşaması değil'; end if;
  pend := st->'ins_pending';
  if not (pend ? uid::text) then raise exception 'Karar verilmiş'; end if;
  if p_take then
    for i in 0..5 loop
      if (st->'spots'->i->>'owner')::uuid = uid then need := need + (st->'spots'->i->>'bet')::numeric / 2; end if;
    end loop;
    perform public.bj_charge(uid, need);
    for i in 0..5 loop
      if (st->'spots'->i->>'owner')::uuid = uid then
        st := jsonb_set(st, array['spots', i::text, 'ins'], to_jsonb((st->'spots'->i->>'bet')::numeric / 2));
      end if;
    end loop;
  end if;
  pend := pend - uid::text;
  st := jsonb_set(st, '{ins_pending}', pend);
  if jsonb_array_length(pend) = 0 then st := public.bj_after_insurance(st); end if;
  perform public.bj_save(st);
  return st;
end $$;
grant execute on function public.bj_insure(boolean) to authenticated;

create or replace function public.bj_action(p_act text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); st jsonb; cur jsonb; s int; h int; hd jsonb; sp jsonb; c text; h2 jsonb; b numeric; r0 text; r1 text;
begin
  if uid is null then raise exception 'oturum yok'; end if;
  select state into st from public.bj_table where id = 1 for update;
  if st->>'phase' <> 'play' then raise exception 'Sıra sende değil'; end if;
  cur := st->'cur'; s := (cur->>'s')::int; h := (cur->>'h')::int;
  sp := st->'spots'->s;
  if (sp->>'owner')::uuid <> uid then raise exception 'Sıra sende değil'; end if;
  hd := sp->'hands'->h; b := (hd->>'bet')::numeric;
  if p_act = 'hit' then
    hd := jsonb_set(hd, '{cards}', (hd->'cards') || to_jsonb(public.bj_draw()));
    if public.bj_val(hd->'cards') >= 21 then hd := jsonb_set(hd, '{done}', 'true'); end if;
  elsif p_act = 'stand' then
    hd := jsonb_set(hd, '{done}', 'true');
  elsif p_act = 'double' then
    if jsonb_array_length(hd->'cards') <> 2 then raise exception 'İkiye katlama yalnız ilk iki kartta'; end if;
    perform public.bj_charge(uid, b);
    hd := jsonb_set(hd, '{bet}', to_jsonb(b * 2));
    hd := jsonb_set(hd, '{dbl}', 'true');
    hd := jsonb_set(hd, '{cards}', (hd->'cards') || to_jsonb(public.bj_draw()));
    hd := jsonb_set(hd, '{done}', 'true');
  elsif p_act = 'split' then
    r0 := public.bj_rank(hd->'cards'->>0); r1 := public.bj_rank(hd->'cards'->>1);
    if jsonb_array_length(hd->'cards') <> 2 or r0 <> r1 or coalesce((hd->>'split')::boolean,false) or jsonb_array_length(sp->'hands') >= 2 then
      raise exception 'Bölünemez'; end if;
    perform public.bj_charge(uid, b);
    c := hd->'cards'->>1;
    hd := jsonb_set(hd, '{cards}', jsonb_build_array(hd->'cards'->>0, public.bj_draw()));
    hd := jsonb_set(hd, '{split}', 'true');
    h2 := jsonb_build_object('cards', jsonb_build_array(c, public.bj_draw()), 'bet', b, 'done', false, 'dbl', false, 'split', true, 'bj', false);
    if r0 = 'A' then hd := jsonb_set(hd, '{done}', 'true'); h2 := jsonb_set(h2, '{done}', 'true');
    elsif public.bj_val(hd->'cards') = 21 then hd := jsonb_set(hd, '{done}', 'true'); end if;
    if public.bj_val(h2->'cards') = 21 and r0 <> 'A' then h2 := jsonb_set(h2, '{done}', 'true'); end if;
    sp := jsonb_set(sp, '{hands}', (sp->'hands') || h2);
  else
    raise exception 'Bilinmeyen hamle';
  end if;
  sp := jsonb_set(sp, array['hands', h::text], hd);
  st := jsonb_set(st, array['spots', s::text], sp);
  if coalesce((hd->>'done')::boolean,false) then st := public.bj_advance(st);
  else st := jsonb_set(st, '{deadline}', to_jsonb(now() + interval '25 seconds')); end if;
  perform public.bj_save(st);
  return st;
end $$;
grant execute on function public.bj_action(text) to authenticated;

-- zaman aşımı ve tur geçişleri (istemciler masadayken birkaç saniyede bir çağırır)
create or replace function public.bj_tick() returns jsonb
language plpgsql security definer set search_path = public as $$
declare st jsonb; dl timestamptz; i int; anybet boolean := false; cur jsonb; hd jsonb;
begin
  if auth.uid() is null then raise exception 'oturum yok'; end if;
  select state into st from public.bj_table where id = 1 for update;
  if st = '{}'::jsonb then st := public.bj_empty_state(); perform public.bj_save(st); return st; end if;
  dl := (st->>'deadline')::timestamptz;
  if dl is null or dl > now() then return st; end if;
  if st->>'phase' = 'bet' then
    for i in 0..5 loop if coalesce((st->'spots'->i->>'bet')::numeric,0) > 0 then anybet := true; end if; end loop;
    if anybet then st := public.bj_deal_internal(st); else st := jsonb_set(st, '{deadline}', 'null'); end if;
  elsif st->>'phase' = 'insure' then
    st := public.bj_after_insurance(st);
  elsif st->>'phase' = 'play' then
    cur := st->'cur';
    hd := st->'spots'->(cur->>'s')::int->'hands'->(cur->>'h')::int;
    hd := jsonb_set(hd, '{done}', 'true');
    st := jsonb_set(st, array['spots', cur->>'s', 'hands', cur->>'h'], hd);
    st := public.bj_advance(st);
  elsif st->>'phase' = 'settle' then
    st := public.bj_reset_round(st);
  end if;
  perform public.bj_save(st);
  return st;
end $$;
grant execute on function public.bj_tick() to authenticated;

-- Realtime
do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='bj_table') then
    alter publication supabase_realtime add table public.bj_table;
  end if;
end $$;

-- ilk durum
update public.bj_table set state = public.bj_empty_state() where id = 1 and state = '{}'::jsonb;
