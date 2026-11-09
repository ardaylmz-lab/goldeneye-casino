-- ===== Faz 3: ortak Texas Hold'em masası (sunucu taraflı) =====
-- Tek masa, 3 koltuk. Deste ve kapalı kartlar pk_secret'ta; herkese açık durum pk_table.state'te (kapalı kartlar yalnız showdown'da).
-- Oyuncu kendi kartlarını pk_my_cards() ile alır. Boş koltuklar botlarla dolar; botlar ve süre aşımı pk_tick() ile işler.
-- Tekrar çalıştırmak güvenlidir. bj_engine.sql (bj_charge/bj_pay) kurulu olmalıdır.

create table if not exists public.pk_table (
  id int primary key default 1 check (id = 1),
  state jsonb not null default '{}'::jsonb,
  version bigint not null default 0,
  updated_at timestamptz not null default now()
);
insert into public.pk_table (id) values (1) on conflict (id) do nothing;
alter table public.pk_table enable row level security;
drop policy if exists "pk_table: herkes okur" on public.pk_table;
create policy "pk_table: herkes okur" on public.pk_table for select to authenticated using (true);

create table if not exists public.pk_secret (
  id int primary key default 1 check (id = 1),
  deck jsonb not null default '[]'::jsonb,
  holes jsonb not null default '{}'::jsonb
);
insert into public.pk_secret (id) values (1) on conflict (id) do nothing;
alter table public.pk_secret enable row level security; -- politika yok: doğrudan okunamaz

create table if not exists public.pk_presence (user_id uuid primary key, seen timestamptz not null default now());
alter table public.pk_presence enable row level security;

create or replace function public.pk_empty_state() returns jsonb language sql immutable as $$
  select jsonb_build_object('phase','idle','hand',0,'button',-1,'sb',5,'bb',10,'seats',jsonb_build_array(null,null,null),'board','[]'::jsonb,'cur',-1,'curBet',0,'minRaise',10,'deadline',null,'botAt',null,'nextAt',null,'pots',null,'results',null,'winners','[]'::jsonb,'log','[]'::jsonb)
$$;
create or replace function public.pk_save(st jsonb) returns void language sql as $$
  update public.pk_table set state = st, version = version + 1, updated_at = now() where id = 1
$$;

-- ---------- kart yardımcıları ----------
create or replace function public.pk_rank(c text) returns int language sql immutable as $$
  select array_position(array['2','3','4','5','6','7','8','9','10','J','Q','K','A'], left(c, length(c)-1)) - 1
$$;
create or replace function public.pk_rname(r int) returns text language sql immutable as $$
  select (array['2','3','4','5','6','7','8','9','10','J','Q','K','A'])[r+1]
$$;
create or replace function public.pk_deck() returns jsonb language sql volatile as $$
  select jsonb_agg(c order by random()) from (select r || s as c from unnest(array['2','3','4','5','6','7','8','9','10','J','Q','K','A']) r cross join unnest(array['♠','♥','♦','♣']) s) q
$$;
-- kent tepesi: present[1..13] (rank 0..12); As alçak sayılır; yoksa -1
create or replace function public.pk_straight_top(present boolean[]) returns int language plpgsql immutable as $$
declare t int; k int; idx int; ok boolean;
begin
  for t in reverse 12..3 loop
    ok := true;
    for k in 0..4 loop idx := t - k; if idx < 0 then idx := 12; end if; if not present[idx+1] then ok := false; exit; end if; end loop;
    if ok then return t; end if;
  end loop;
  return -1;
end $$;
-- 5–7 karttan en iyi 5: {cat, score, best, name}
create or replace function public.pk_eval(cards text[]) returns jsonb language plpgsql immutable as $$
declare c text; r int; s text; cnt int[] := array_fill(0, array[13]); present boolean[] := array_fill(false, array[13]);
  scnt jsonb := '{}'::jsonb; fs text := null; fr int[]; fpresent boolean[]; st int; best text[] := '{}'; kick int[] := '{}'; cat int; name text; score numeric := 0; i int; k int;
  g4 int := -1; g3 int := -1; p1 int := -1; p2 int := -1; others int[] := '{}'; byr text[][]; tmp text[]; found text;
begin
  foreach c in array cards loop r := public.pk_rank(c); s := right(c,1); cnt[r+1] := cnt[r+1] + 1; present[r+1] := true; scnt := jsonb_set(scnt, array[s], to_jsonb(coalesce((scnt->>s)::int,0)+1)); end loop;
  for s in select key from jsonb_each(scnt) where value::int >= 5 loop fs := s; end loop;
  -- floş kent / royal
  if fs is not null then
    fpresent := array_fill(false, array[13]);
    foreach c in array cards loop if right(c,1) = fs then fpresent[public.pk_rank(c)+1] := true; end if; end loop;
    st := public.pk_straight_top(fpresent);
    if st >= 0 then
      for k in 0..4 loop r := st - k; if r < 0 then r := 12; end if; best := best || (public.pk_rname(r) || fs); end loop;
      kick := array[st]; cat := 8; name := case when st = 12 then 'Royal Floş' else 'Floş Kent, ' || public.pk_rname(st) || ' tepe' end;
      return public.pk_score(cat, kick, best, name);
    end if;
  end if;
  -- gruplar
  for r in reverse 12..0 loop
    if cnt[r+1] = 4 then g4 := r;
    elsif cnt[r+1] = 3 then if g3 < 0 then g3 := r; elsif p1 < 0 then p1 := r; end if;
    elsif cnt[r+1] = 2 then if p1 < 0 then p1 := r; elsif p2 < 0 then p2 := r; end if;
    end if;
  end loop;
  if g4 >= 0 then
    for r in reverse 12..0 loop if cnt[r+1] > 0 and r <> g4 then kick := array[g4, r]; exit; end if; end loop;
    best := public.pk_pick(cards, g4, 4) || public.pk_pick(cards, kick[2], 1); return public.pk_score(7, kick, best, 'Kare, ' || public.pk_rname(g4));
  end if;
  if g3 >= 0 and p1 >= 0 then
    best := public.pk_pick(cards, g3, 3) || public.pk_pick(cards, p1, 2); return public.pk_score(6, array[g3, p1], best, 'Full House, ' || public.pk_rname(g3) || ' dolu ' || public.pk_rname(p1));
  end if;
  if fs is not null then
    select array_agg(x order by public.pk_rank(x) desc) into tmp from unnest(cards) x where right(x,1) = fs; best := tmp[1:5];
    kick := '{}'; foreach c in array best loop kick := kick || public.pk_rank(c); end loop;
    return public.pk_score(5, kick, best, 'Floş, ' || public.pk_rname(kick[1]) || ' yüksek');
  end if;
  st := public.pk_straight_top(present);
  if st >= 0 then
    for k in 0..4 loop r := st - k; if r < 0 then r := 12; end if; best := best || public.pk_pick(cards, r, 1); end loop;
    return public.pk_score(4, array[st], best, 'Kent, ' || public.pk_rname(st) || ' tepe');
  end if;
  if g3 >= 0 then
    kick := array[g3]; for r in reverse 12..0 loop if cnt[r+1] > 0 and r <> g3 and array_length(kick,1) < 3 then kick := kick || r; end if; end loop;
    best := public.pk_pick(cards, g3, 3) || public.pk_pick(cards, kick[2], 1) || public.pk_pick(cards, kick[3], 1);
    return public.pk_score(3, kick, best, 'Üçlü, ' || public.pk_rname(g3));
  end if;
  if p1 >= 0 and p2 >= 0 then
    for r in reverse 12..0 loop if cnt[r+1] > 0 and r <> p1 and r <> p2 then kick := array[p1, p2, r]; exit; end if; end loop;
    best := public.pk_pick(cards, p1, 2) || public.pk_pick(cards, p2, 2) || public.pk_pick(cards, kick[3], 1);
    return public.pk_score(2, kick, best, 'İki Çift, ' || public.pk_rname(p1) || ' ve ' || public.pk_rname(p2));
  end if;
  if p1 >= 0 then
    kick := array[p1]; for r in reverse 12..0 loop if cnt[r+1] > 0 and r <> p1 and array_length(kick,1) < 4 then kick := kick || r; end if; end loop;
    best := public.pk_pick(cards, p1, 2) || public.pk_pick(cards, kick[2], 1) || public.pk_pick(cards, kick[3], 1) || public.pk_pick(cards, kick[4], 1);
    return public.pk_score(1, kick, best, 'Çift, ' || public.pk_rname(p1));
  end if;
  for r in reverse 12..0 loop if cnt[r+1] > 0 and array_length(kick,1) is distinct from 5 and coalesce(array_length(kick,1),0) < 5 then kick := kick || r; best := best || public.pk_pick(cards, r, 1); end if; end loop;
  return public.pk_score(0, kick, best, 'Yüksek Kart, ' || public.pk_rname(kick[1]));
end $$;
create or replace function public.pk_pick(cards text[], r int, n int) returns text[] language sql immutable as $$
  select coalesce(array_agg(x), '{}') from (select x from unnest(cards) x where public.pk_rank(x) = r limit n) q
$$;
create or replace function public.pk_score(cat int, kick int[], best text[], name text) returns jsonb language plpgsql immutable as $$
declare sc numeric := cat; i int;
begin
  for i in 1..5 loop sc := sc * 15 + coalesce(kick[i] + 1, 0); end loop;
  return jsonb_build_object('cat', cat, 'score', sc, 'best', to_jsonb(best), 'name', name);
end $$;

-- ---------- durum yardımcıları ----------
create or replace function public.pk_sget(st jsonb, i int) returns jsonb language sql immutable as $$ select st->'seats'->i $$;
create or replace function public.pk_sset(st jsonb, i int, k text, v jsonb) returns jsonb language sql immutable as $$ select jsonb_set(st, array['seats', i::text, k], v) $$;
create or replace function public.pk_inhand(s jsonb) returns boolean language sql immutable as $$ select s is not null and jsonb_typeof(s) = 'object' and (s->>'cardsN')::int = 2 and not (s->>'folded')::boolean $$;
create or replace function public.pk_canact(s jsonb) returns boolean language sql immutable as $$ select public.pk_inhand(s) and not (s->>'allin')::boolean $$;
create or replace function public.pk_pot(st jsonb) returns numeric language sql immutable as $$ select coalesce(sum((s->>'total')::numeric), 0) from jsonb_array_elements(st->'seats') s where jsonb_typeof(s) = 'object' $$;
create or replace function public.pk_next(st jsonb, i int, mode text) returns int language plpgsql immutable as $$
declare k int; j int; s jsonb;
begin
  for k in 1..3 loop j := (i + k) % 3; s := public.pk_sget(st, j);
    if mode = 'act' and public.pk_canact(s) and (not (s->>'acted')::boolean or (s->>'bet')::numeric < (st->>'curBet')::numeric) then return j; end if;
    if mode = 'canact' and public.pk_canact(s) then return j; end if;
    if mode = 'playing' and s is not null and jsonb_typeof(s) = 'object' and (s->>'stack')::numeric > 0 and (s->>'cardsN')::int = 2 then return j; end if;
    if mode = 'ready' and s is not null and jsonb_typeof(s) = 'object' and (s->>'stack')::numeric > 0 then return j; end if;
  end loop;
  return -1;
end $$;
create or replace function public.pk_postbet(st jsonb, i int, amt numeric) returns jsonb language plpgsql immutable as $$
declare s jsonb := public.pk_sget(st, i); stack numeric := (s->>'stack')::numeric; a numeric := least(amt, stack);
begin
  st := public.pk_sset(st, i, 'stack', to_jsonb(round(stack - a, 2)));
  st := public.pk_sset(st, i, 'bet', to_jsonb(round((s->>'bet')::numeric + a, 2)));
  st := public.pk_sset(st, i, 'total', to_jsonb(round((s->>'total')::numeric + a, 2)));
  if stack - a <= 0.001 then st := public.pk_sset(st, i, 'stack', '0'); st := public.pk_sset(st, i, 'allin', 'true'); end if;
  return st;
end $$;
-- hamle süresi: insana 25 sn, bota kısa gecikme
create or replace function public.pk_timers(st jsonb) returns jsonb language plpgsql volatile as $$
declare cur int := (st->>'cur')::int; s jsonb;
begin
  if cur < 0 then return jsonb_set(jsonb_set(st, '{deadline}', 'null'), '{botAt}', 'null'); end if;
  s := public.pk_sget(st, cur);
  if (s->>'bot')::boolean then return jsonb_set(jsonb_set(st, '{botAt}', to_jsonb(now() + interval '1.4 seconds')), '{deadline}', 'null'); end if;
  return jsonb_set(jsonb_set(st, '{deadline}', to_jsonb(now() + interval '25 seconds')), '{botAt}', 'null');
end $$;

-- ---------- el akışı ----------
create or replace function public.pk_start_hand(st jsonb) returns jsonb language plpgsql volatile as $$
declare i int; s jsonb; n int := 0; first int := -1; v_deck jsonb; v_holes jsonb := '{}'::jsonb; sbI int; bbI int; bal numeric; r numeric; uid uuid;
begin
  -- yeniden alım: insan bakiyeden (yetmezse kalkar), bot 500'e tamamlanır
  for i in 0..2 loop s := public.pk_sget(st, i); if s is null or jsonb_typeof(s) <> 'object' then continue; end if;
    if (s->>'stack')::numeric < (st->>'bb')::numeric then
      if (s->>'bot')::boolean then st := public.pk_sset(st, i, 'stack', '500');
      else uid := (s->>'user')::uuid; select balance into bal from public.profiles where id = uid; r := least(500, floor(coalesce(bal,0)));
        if r >= 50 then perform public.bj_charge(uid, r); st := public.pk_sset(st, i, 'stack', to_jsonb(round((s->>'stack')::numeric + r, 2)));
        else perform public.bj_pay(uid, (s->>'stack')::numeric); st := jsonb_set(st, array['seats', i::text], 'null'); end if;
      end if;
    end if;
  end loop;
  for i in 0..2 loop s := public.pk_sget(st, i); if s is not null and jsonb_typeof(s) = 'object' and (s->>'stack')::numeric > 0 then n := n + 1; end if; end loop;
  if n < 2 then return jsonb_set(jsonb_set(st, '{phase}', '"idle"'), '{cur}', '-1'); end if;
  v_deck := public.pk_deck();
  st := jsonb_set(st, '{hand}', to_jsonb((st->>'hand')::int + 1)); st := jsonb_set(st, '{board}', '[]'); st := jsonb_set(st, '{results}', 'null'); st := jsonb_set(st, '{pots}', 'null'); st := jsonb_set(st, '{winners}', '[]'); st := jsonb_set(st, '{log}', '[]'); st := jsonb_set(st, '{nextAt}', 'null');
  for i in 0..2 loop s := public.pk_sget(st, i); if s is null or jsonb_typeof(s) <> 'object' then continue; end if;
    st := public.pk_sset(st, i, 'bet', '0'); st := public.pk_sset(st, i, 'total', '0'); st := public.pk_sset(st, i, 'allin', 'false'); st := public.pk_sset(st, i, 'acted', 'false'); st := public.pk_sset(st, i, 'cards', 'null');
    if (s->>'stack')::numeric > 0 then st := public.pk_sset(st, i, 'folded', 'false'); st := public.pk_sset(st, i, 'cardsN', '2');
      v_holes := v_holes || jsonb_build_object(i::text, jsonb_build_array(v_deck->0, v_deck->1)); v_deck := v_deck - 0 - 0;
    else st := public.pk_sset(st, i, 'folded', 'true'); st := public.pk_sset(st, i, 'cardsN', '0'); end if;
  end loop;
  update public.pk_secret set deck = v_deck, holes = v_holes where id = 1;
  st := jsonb_set(st, '{button}', to_jsonb(public.pk_next(st, (st->>'button')::int, 'playing')));
  if n = 2 then sbI := (st->>'button')::int; bbI := public.pk_next(st, sbI, 'playing');
  else sbI := public.pk_next(st, (st->>'button')::int, 'playing'); bbI := public.pk_next(st, sbI, 'playing'); end if;
  st := public.pk_postbet(st, sbI, (st->>'sb')::numeric); st := public.pk_postbet(st, bbI, (st->>'bb')::numeric);
  st := jsonb_set(st, '{sbI}', to_jsonb(sbI)); st := jsonb_set(st, '{bbI}', to_jsonb(bbI));
  st := jsonb_set(st, '{phase}', '"preflop"'); st := jsonb_set(st, '{curBet}', to_jsonb((st->>'bb')::numeric)); st := jsonb_set(st, '{minRaise}', to_jsonb((st->>'bb')::numeric));
  st := jsonb_set(st, '{cur}', to_jsonb(public.pk_next(st, bbI, 'canact')));
  if (st->>'cur')::int < 0 then st := public.pk_finish_round(st); else st := public.pk_timers(st); end if;
  return st;
end $$;

create or replace function public.pk_legal(st jsonb, i int) returns jsonb language plpgsql immutable as $$
declare s jsonb := public.pk_sget(st, i); tocall numeric; maxto numeric; minto numeric;
begin
  if (st->>'cur')::int <> i or st->>'phase' not in ('preflop','flop','turn','river') then return null; end if;
  tocall := round((st->>'curBet')::numeric - (s->>'bet')::numeric, 2); maxto := round((s->>'bet')::numeric + (s->>'stack')::numeric, 2);
  minto := least(maxto, round((st->>'curBet')::numeric + (st->>'minRaise')::numeric, 2));
  return jsonb_build_object('check', tocall <= 0, 'call', case when tocall > 0 then least(tocall, (s->>'stack')::numeric) else 0 end, 'canRaise', maxto > (st->>'curBet')::numeric, 'minRaise', minto, 'maxRaise', maxto, 'toCall', tocall);
end $$;

create or replace function public.pk_apply(st jsonb, i int, a text, amt numeric) returns jsonb language plpgsql volatile as $$
declare L jsonb := public.pk_legal(st, i); s jsonb; pay numeric; size numeric; j int; live int := 0; nx int; shown numeric;
begin
  if L is null then raise exception 'Sıra sende değil'; end if;
  s := public.pk_sget(st, i);
  if a = 'fold' then st := public.pk_sset(st, i, 'folded', 'true');
  elsif a = 'check' then if not (L->>'check')::boolean then raise exception 'Check yok'; end if;
  elsif a = 'call' then if (L->>'toCall')::numeric <= 0 then raise exception 'Call yok'; end if; st := public.pk_postbet(st, i, (L->>'toCall')::numeric);
  elsif a = 'raise' then
    if not (L->>'canRaise')::boolean then raise exception 'Yükseltme yok'; end if;
    amt := round(coalesce(amt, 0), 2); if amt >= (L->>'maxRaise')::numeric then amt := (L->>'maxRaise')::numeric; elsif amt < (L->>'minRaise')::numeric then amt := (L->>'minRaise')::numeric; end if;
    pay := round(amt - (s->>'bet')::numeric, 2); st := public.pk_postbet(st, i, pay);
    size := round(amt - (st->>'curBet')::numeric, 2); if size >= (st->>'minRaise')::numeric then st := jsonb_set(st, '{minRaise}', to_jsonb(size)); end if;
    st := jsonb_set(st, '{curBet}', to_jsonb(amt));
    for j in 0..2 loop if j <> i and public.pk_sget(st, j) is not null and jsonb_typeof(public.pk_sget(st, j)) = 'object' then st := public.pk_sset(st, j, 'acted', 'false'); end if; end loop;
  else raise exception 'Bilinmeyen hamle'; end if;
  st := public.pk_sset(st, i, 'acted', 'true');
  shown := case when a = 'raise' then (public.pk_sget(st, i)->>'bet')::numeric when a = 'call' then (L->>'toCall')::numeric else 0 end;
  st := jsonb_set(st, '{log}', (st->'log') || jsonb_build_object('i', i, 'a', a, 'amt', shown, 'allin', (public.pk_sget(st, i)->>'allin')::boolean, 'n', jsonb_array_length(st->'log')));
  for j in 0..2 loop if public.pk_inhand(public.pk_sget(st, j)) then live := live + 1; end if; end loop;
  if live = 1 then return public.pk_award(st); end if;
  nx := public.pk_next(st, i, 'act');
  if nx >= 0 then st := jsonb_set(st, '{cur}', to_jsonb(nx)); return public.pk_timers(st); end if;
  return public.pk_finish_round(st);
end $$;

create or replace function public.pk_deal_street(st jsonb) returns jsonb language plpgsql volatile as $$
declare v_deck jsonb; ph text := st->>'phase'; board jsonb := st->'board';
begin
  select pk_secret.deck into v_deck from public.pk_secret where id = 1;
  if ph = 'preflop' then v_deck := v_deck - 0; board := board || jsonb_build_array(v_deck->0, v_deck->1, v_deck->2); v_deck := v_deck - 0 - 0 - 0; st := jsonb_set(st, '{phase}', '"flop"');
  elsif ph = 'flop' then v_deck := v_deck - 0; board := board || jsonb_build_array(v_deck->0); v_deck := v_deck - 0; st := jsonb_set(st, '{phase}', '"turn"');
  elsif ph = 'turn' then v_deck := v_deck - 0; board := board || jsonb_build_array(v_deck->0); v_deck := v_deck - 0; st := jsonb_set(st, '{phase}', '"river"');
  else return st; end if;
  update public.pk_secret set deck = v_deck where id = 1;
  return jsonb_set(st, '{board}', board);
end $$;

create or replace function public.pk_finish_round(st jsonb) returns jsonb language plpgsql volatile as $$
declare j int; actors int := 0; s jsonb;
begin
  for j in 0..2 loop s := public.pk_sget(st, j); if s is not null and jsonb_typeof(s) = 'object' then st := public.pk_sset(st, j, 'bet', '0'); st := public.pk_sset(st, j, 'acted', 'false'); if public.pk_canact(s) then actors := actors + 1; end if; end if; end loop;
  st := jsonb_set(st, '{curBet}', '0'); st := jsonb_set(st, '{minRaise}', to_jsonb((st->>'bb')::numeric));
  if actors <= 1 then
    while st->>'phase' in ('preflop','flop','turn') loop st := public.pk_deal_street(st); end loop;
    return public.pk_showdown(st);
  end if;
  if st->>'phase' = 'river' then return public.pk_showdown(st); end if;
  st := public.pk_deal_street(st);
  st := jsonb_set(st, '{cur}', to_jsonb(public.pk_next(st, (st->>'button')::int, 'canact')));
  return public.pk_timers(st);
end $$;

create or replace function public.pk_showdown(st jsonb) returns jsonb language plpgsql volatile as $$
declare holes jsonb; j int; s jsonb; ev jsonb[] := array[null,null,null]::jsonb[]; contrib numeric[] := array[0,0,0]; live boolean[] := array[false,false,false];
  pots jsonb := '[]'::jsonb; m numeric; amt numeric; elig int[]; take numeric; best int; ws int[]; share numeric; rem numeric; won numeric[] := array[0,0,0]; res jsonb := '[]'::jsonb; k int; winners jsonb := '[]'::jsonb; rest numeric; cards text[]; ord int[];
begin
  select pk_secret.holes into holes from public.pk_secret where id = 1;
  st := jsonb_set(st, '{phase}', '"showdown"');
  for j in 0..2 loop s := public.pk_sget(st, j); if s is null or jsonb_typeof(s) <> 'object' then continue; end if;
    contrib[j+1] := (s->>'total')::numeric; live[j+1] := public.pk_inhand(s);
    if live[j+1] then
      select array_agg(x) into cards from jsonb_array_elements_text((holes->(j::text)) || (st->'board')) x;
      ev[j+1] := public.pk_eval(cards); st := public.pk_sset(st, j, 'cards', holes->(j::text));
    end if;
  end loop;
  -- yan potlar
  loop
    m := null; for j in 1..3 loop if live[j] and contrib[j] > 0 and (m is null or contrib[j] < m) then m := contrib[j]; end if; end loop;
    exit when m is null;
    amt := 0; elig := '{}';
    for j in 1..3 loop take := least(contrib[j], m); amt := round(amt + take, 2); contrib[j] := round(contrib[j] - take, 2); if live[j] and take >= m - 0.001 then elig := elig || (j-1); end if; end loop;
    pots := pots || jsonb_build_object('amt', amt, 'elig', to_jsonb(elig));
  end loop;
  rest := 0; for j in 1..3 loop rest := rest + contrib[j]; end loop;
  if rest > 0 and jsonb_array_length(pots) > 0 then k := jsonb_array_length(pots) - 1; pots := jsonb_set(pots, array[k::text, 'amt'], to_jsonb(round((pots->k->>'amt')::numeric + rest, 2))); end if;
  -- her pot en iyi ele; eşitlikte bölünür, artık düğmeden sonraki ilk kazanana
  for k in 0..jsonb_array_length(pots)-1 loop
    best := -1; ws := '{}';
    for j in select value::int from jsonb_array_elements_text(pots->k->'elig') loop
      if best < 0 or (ev[j+1]->>'score')::numeric > (ev[best+1]->>'score')::numeric then best := j; end if;
    end loop;
    for j in select value::int from jsonb_array_elements_text(pots->k->'elig') loop if (ev[j+1]->>'score')::numeric = (ev[best+1]->>'score')::numeric then ws := ws || j; end if; end loop;
    share := floor((pots->k->>'amt')::numeric * 100 / array_length(ws,1)) / 100; rem := round((pots->k->>'amt')::numeric - share * array_length(ws,1), 2);
    select array_agg(x order by ((x - (st->>'button')::int + 3) % 3)) into ord from unnest(ws) x;
    foreach j in array ws loop won[j+1] := round(won[j+1] + share, 2); end loop;
    if rem > 0 then won[ord[1]+1] := round(won[ord[1]+1] + rem, 2); end if;
    pots := jsonb_set(pots, array[k::text, 'winners'], to_jsonb(ws));
  end loop;
  for j in 0..2 loop s := public.pk_sget(st, j); if s is null or jsonb_typeof(s) <> 'object' then res := res || 'null'::jsonb; continue; end if;
    res := res || jsonb_build_object('i', j, 'inHand', live[j+1], 'win', won[j+1], 'net', round(won[j+1] - (s->>'total')::numeric, 2), 'ev', ev[j+1]);
    if won[j+1] > 0 then st := public.pk_sset(st, j, 'stack', to_jsonb(round((s->>'stack')::numeric + won[j+1], 2))); winners := winners || to_jsonb(j); end if;
  end loop;
  st := jsonb_set(st, '{pots}', pots); st := jsonb_set(st, '{results}', res); st := jsonb_set(st, '{winners}', winners);
  st := jsonb_set(st, '{phase}', '"done"'); st := jsonb_set(st, '{cur}', '-1'); st := jsonb_set(st, '{deadline}', 'null'); st := jsonb_set(st, '{botAt}', 'null');
  st := jsonb_set(st, '{nextAt}', to_jsonb(now() + interval '7 seconds'));
  return st;
end $$;

create or replace function public.pk_award(st jsonb) returns jsonb language plpgsql volatile as $$
declare j int; w int := -1; total numeric := public.pk_pot(st); s jsonb; res jsonb := '[]'::jsonb;
begin
  for j in 0..2 loop if public.pk_inhand(public.pk_sget(st, j)) then w := j; end if; end loop;
  for j in 0..2 loop s := public.pk_sget(st, j); if s is null or jsonb_typeof(s) <> 'object' then res := res || 'null'::jsonb; continue; end if;
    res := res || jsonb_build_object('i', j, 'inHand', public.pk_inhand(s), 'win', case when j = w then total else 0 end, 'net', round((case when j = w then total else 0 end) - (s->>'total')::numeric, 2), 'ev', null);
  end loop;
  st := public.pk_sset(st, w, 'stack', to_jsonb(round((public.pk_sget(st, w)->>'stack')::numeric + total, 2)));
  st := jsonb_set(st, '{results}', res); st := jsonb_set(st, '{winners}', jsonb_build_array(w)); st := jsonb_set(st, '{pots}', 'null');
  st := jsonb_set(st, '{phase}', '"done"'); st := jsonb_set(st, '{cur}', '-1'); st := jsonb_set(st, '{deadline}', 'null'); st := jsonb_set(st, '{botAt}', 'null');
  st := jsonb_set(st, '{nextAt}', to_jsonb(now() + interval '5 seconds'));
  return st;
end $$;

-- ---------- bot ----------
create or replace function public.pk_strength(st jsonb, i int, hole text[]) returns numeric language plpgsql volatile as $$
declare a int; b int; hi int; lo int; suited boolean; s numeric; ev jsonb; cards text[]; cat int; board text[]; top int := -1; c text; pr int := 0; pairr int; nsuit int; rs int[]; run int := 1; bestrun int := 1; k int;
begin
  if hole is null or array_length(hole,1) < 2 then return 0; end if;
  select coalesce(array_agg(x), '{}') into board from jsonb_array_elements_text(st->'board') x;
  a := public.pk_rank(hole[1]); b := public.pk_rank(hole[2]); hi := greatest(a,b); lo := least(a,b); suited := right(hole[1],1) = right(hole[2],1);
  if coalesce(array_length(board,1),0) = 0 then
    if a = b then return .5 + a/12.0*.5; end if;
    s := .12 + hi/12.0*.3 + lo/12.0*.12; if suited then s := s + .06; end if; if hi - lo = 1 then s := s + .05; elsif hi - lo = 2 then s := s + .02; end if; if hi = 12 then s := s + .06; end if;
    return least(.92, s);
  end if;
  cards := hole || board; ev := public.pk_eval(cards); cat := (ev->>'cat')::int;
  s := (array[.1,.35,.55,.7,.82,.86,.93,.97,1.0])[cat+1];
  foreach c in array board loop top := greatest(top, public.pk_rank(c)); end loop;
  if cat = 1 then
    for k in 0..jsonb_array_length(ev->'best')-1 loop if (ev->'best'->>k) = any(hole) then pr := pr + 1; end if; end loop;
    pairr := public.pk_rank(ev->'best'->>0);
    if pr = 2 then s := s + .12; elsif pairr >= top then s := s + .1; else s := s - .08; end if;
  end if;
  if cat = 0 then s := .06 + hi/12.0*.12; end if;
  if array_length(board,1) < 5 then
    select max(n) into nsuit from (select count(*) n from unnest(cards) x group by right(x,1)) q; if nsuit = 4 then s := s + .14; end if;
    select array_agg(distinct public.pk_rank(x) order by public.pk_rank(x)) into rs from unnest(cards) x;
    for k in 2..array_length(rs,1) loop if rs[k] = rs[k-1] + 1 then run := run + 1; else run := 1; end if; bestrun := greatest(bestrun, run); end loop;
    if bestrun = 4 and cat < 4 then s := s + .1; end if;
  end if;
  return least(1, s);
end $$;
create or replace function public.pk_bot(st jsonb, i int) returns jsonb language plpgsql volatile as $$
declare L jsonb := public.pk_legal(st, i); holes jsonb; hole text[]; s numeric; P numeric := public.pk_pot(st); tocall numeric; odds numeric; r numeric := random(); bb numeric := (st->>'bb')::numeric;
begin
  if L is null then return null; end if;
  select pk_secret.holes into holes from public.pk_secret where id = 1;
  select array_agg(x) into hole from jsonb_array_elements_text(holes->(i::text)) x;
  s := public.pk_strength(st, i, hole); tocall := (L->>'toCall')::numeric; odds := case when tocall > 0 then tocall / (P + tocall) else 0 end;
  if jsonb_array_length(st->'board') = 0 then
    if s > .7 and r < .85 then return public.pk_raiseto(st, L, .9); end if;
    if s > .5 and r < .5 then return public.pk_raiseto(st, L, .6); end if;
    if tocall <= 0 then return '{"a":"check"}'::jsonb; end if;
    if s > .42 or (tocall <= bb and s > .25) then return '{"a":"call"}'::jsonb; end if;
    if r < .06 then return public.pk_raiseto(st, L, .8); end if;
    return '{"a":"fold"}'::jsonb;
  end if;
  if tocall <= 0 then
    if s > .75 and r < .8 then return public.pk_raiseto(st, L, .75); end if;
    if s > .5 and r < .45 then return public.pk_raiseto(st, L, .5); end if;
    if s < .3 and r < .1 then return public.pk_raiseto(st, L, .6); end if;
    return '{"a":"check"}'::jsonb;
  end if;
  if s > .85 and r < .8 and (L->>'canRaise')::boolean then return public.pk_raiseto(st, L, 1); end if;
  if s > .6 and r < .35 and (L->>'canRaise')::boolean then return public.pk_raiseto(st, L, .6); end if;
  if s > odds + .12 then return '{"a":"call"}'::jsonb; end if;
  if s > odds - .05 and r < .4 then return '{"a":"call"}'::jsonb; end if;
  if r < .05 and (L->>'canRaise')::boolean then return public.pk_raiseto(st, L, .9); end if;
  return '{"a":"fold"}'::jsonb;
end $$;
create or replace function public.pk_raiseto(st jsonb, L jsonb, f numeric) returns jsonb language plpgsql immutable as $$
declare bb numeric := (st->>'bb')::numeric; P numeric := public.pk_pot(st); t numeric;
begin
  if not (L->>'canRaise')::boolean then return case when (L->>'toCall')::numeric > 0 then '{"a":"call"}'::jsonb else '{"a":"check"}'::jsonb end; end if;
  t := round(greatest((L->>'minRaise')::numeric, least((L->>'maxRaise')::numeric, (st->>'curBet')::numeric + greatest(bb, round(P * f / bb) * bb))), 2);
  return jsonb_build_object('a', 'raise', 'amt', t);
end $$;

-- ---------- koltuk yönetimi ----------
create or replace function public.pk_humans(st jsonb) returns int language sql immutable as $$ select count(*)::int from jsonb_array_elements(st->'seats') s where jsonb_typeof(s) = 'object' and not (s->>'bot')::boolean $$;
create or replace function public.pk_fill_bots(st jsonb) returns jsonb language plpgsql immutable as $$
declare i int; names text[] := array['Mert','Elif','Can']; used int := 0;
begin
  if public.pk_humans(st) = 0 then
    for i in 0..2 loop if public.pk_sget(st, i) is not null and jsonb_typeof(public.pk_sget(st, i)) = 'object' and (public.pk_sget(st, i)->>'bot')::boolean then st := jsonb_set(st, array['seats', i::text], 'null'); end if; end loop;
    return st;
  end if;
  for i in 0..2 loop
    if public.pk_sget(st, i) is null or jsonb_typeof(public.pk_sget(st, i)) <> 'object' then
      st := jsonb_set(st, array['seats', i::text], jsonb_build_object('user', null, 'name', names[(i % 3) + 1], 'bot', true, 'stack', 500, 'bet', 0, 'total', 0, 'folded', true, 'allin', false, 'acted', false, 'cardsN', 0, 'cards', null));
    end if;
  end loop;
  return st;
end $$;

create or replace function public.pk_sit(p_seat int, p_buyin numeric) returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); st jsonb; s jsonb; nm text; i int; b numeric;
begin
  if uid is null then raise exception 'oturum yok'; end if;
  if p_seat < 0 or p_seat > 2 then raise exception 'geçersiz koltuk'; end if;
  select state into st from public.pk_table where id = 1 for update;
  if st = '{}'::jsonb then st := public.pk_empty_state(); end if;
  for i in 0..2 loop s := public.pk_sget(st, i); if s is not null and jsonb_typeof(s) = 'object' and s->>'user' = uid::text then raise exception 'Zaten masadasın'; end if; end loop;
  s := public.pk_sget(st, p_seat);
  if s is not null and jsonb_typeof(s) = 'object' then
    if not (s->>'bot')::boolean then raise exception 'Bu koltuk dolu'; end if;
    if st->>'phase' in ('preflop','flop','turn','river') and public.pk_inhand(s) then raise exception 'El bitince otur'; end if;
  end if;
  b := least(greatest(round(coalesce(p_buyin, 500)), 50), 2000);
  perform public.bj_charge(uid, b);
  select name into nm from public.profiles where id = uid;
  st := jsonb_set(st, array['seats', p_seat::text], jsonb_build_object('user', uid::text, 'name', coalesce(nm, 'Oyuncu'), 'bot', false, 'stack', b, 'bet', 0, 'total', 0, 'folded', true, 'allin', false, 'acted', false, 'cardsN', 0, 'cards', null));
  insert into public.pk_presence (user_id, seen) values (uid, now()) on conflict (user_id) do update set seen = now();
  st := public.pk_fill_bots(st);
  if st->>'phase' in ('idle','done') then st := jsonb_set(st, '{nextAt}', to_jsonb(now() + interval '1.5 seconds')); if st->>'phase' = 'idle' then st := jsonb_set(st, '{phase}', '"done"'); end if; end if;
  perform public.pk_save(st);
  return st;
end $$;
grant execute on function public.pk_sit(int, numeric) to authenticated;

create or replace function public.pk_leave_seat(st jsonb, i int) returns jsonb language plpgsql volatile as $$
declare s jsonb := public.pk_sget(st, i);
begin
  if s is null or jsonb_typeof(s) <> 'object' then return st; end if;
  if not (s->>'bot')::boolean and (s->>'stack')::numeric > 0 then perform public.bj_pay((s->>'user')::uuid, (s->>'stack')::numeric); end if;
  if st->>'phase' in ('preflop','flop','turn','river') and public.pk_inhand(s) then
    -- eldeyse: sırası ondaysa pas geçer, değilse pas işaretlenir; bahisleri potta kalır, koltuk el bitince boşalır
    st := public.pk_sset(st, i, 'stack', '0'); st := public.pk_sset(st, i, 'bot', 'true'); st := public.pk_sset(st, i, 'leaving', 'true');
    if (st->>'cur')::int = i then st := public.pk_apply(st, i, 'fold', 0); else st := public.pk_sset(st, i, 'folded', 'true'); end if;
    return st;
  end if;
  return jsonb_set(st, array['seats', i::text], 'null');
end $$;
create or replace function public.pk_leave() returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); st jsonb; s jsonb; i int;
begin
  if uid is null then raise exception 'oturum yok'; end if;
  select state into st from public.pk_table where id = 1 for update;
  if st = '{}'::jsonb then return public.pk_empty_state(); end if;
  for i in 0..2 loop s := public.pk_sget(st, i); if s is not null and jsonb_typeof(s) = 'object' and s->>'user' = uid::text then st := public.pk_leave_seat(st, i); end if; end loop;
  delete from public.pk_presence where user_id = uid;
  st := public.pk_fill_bots(st);
  -- insan kalmadıysa masa sıfırlanır (el ortasında bile; botların fişleri sanaldır)
  if public.pk_humans(st) = 0 then st := jsonb_set(public.pk_empty_state(), '{hand}', st->'hand'); end if;
  perform public.pk_save(st);
  return st;
end $$;
grant execute on function public.pk_leave() to authenticated;

create or replace function public.pk_act(p_action text, p_amount numeric) returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); st jsonb; i int := -1; j int; s jsonb;
begin
  if uid is null then raise exception 'oturum yok'; end if;
  select state into st from public.pk_table where id = 1 for update;
  for j in 0..2 loop s := public.pk_sget(st, j); if s is not null and jsonb_typeof(s) = 'object' and s->>'user' = uid::text then i := j; end if; end loop;
  if i < 0 then raise exception 'Masada değilsin'; end if;
  st := public.pk_apply(st, i, p_action, p_amount);
  insert into public.pk_presence (user_id, seen) values (uid, now()) on conflict (user_id) do update set seen = now();
  perform public.pk_save(st);
  return st;
end $$;
grant execute on function public.pk_act(text, numeric) to authenticated;

create or replace function public.pk_my_cards() returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); st jsonb; s jsonb; j int; holes jsonb;
begin
  if uid is null then raise exception 'oturum yok'; end if;
  select state into st from public.pk_table where id = 1;
  select pk_secret.holes into holes from public.pk_secret where id = 1;
  for j in 0..2 loop s := public.pk_sget(st, j); if s is not null and jsonb_typeof(s) = 'object' and s->>'user' = uid::text then return jsonb_build_object('hand', st->'hand', 'seat', j, 'cards', holes->(j::text)); end if; end loop;
  return null;
end $$;
grant execute on function public.pk_my_cards() to authenticated;

create or replace function public.pk_ping() returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return; end if;
  insert into public.pk_presence (user_id, seen) values (auth.uid(), now()) on conflict (user_id) do update set seen = now();
end $$;
grant execute on function public.pk_ping() to authenticated;

-- zamanlayıcı: bot hamlesi, süre aşımı, yeni el, ayrılan/ölü oturumların kaldırılması
create or replace function public.pk_tick() returns jsonb
language plpgsql security definer set search_path = public as $$
declare st jsonb; cur int; s jsonb; d jsonb; L jsonb; i int; changed boolean := false; guard int := 0;
begin
  if auth.uid() is null then raise exception 'oturum yok'; end if;
  insert into public.pk_presence (user_id, seen) values (auth.uid(), now()) on conflict (user_id) do update set seen = now();
  select state into st from public.pk_table where id = 1 for update;
  if st = '{}'::jsonb then st := public.pk_empty_state(); perform public.pk_save(st); return st; end if;
  -- bot hamleleri ve süre aşımları (botlar zincirleme oynayabilir)
  while st->>'phase' in ('preflop','flop','turn','river') and guard < 12 loop
    guard := guard + 1; cur := (st->>'cur')::int; if cur < 0 then exit; end if; s := public.pk_sget(st, cur);
    if (s->>'bot')::boolean then
      if (st->>'botAt') is null or (st->>'botAt')::timestamptz <= now() then d := public.pk_bot(st, cur); st := public.pk_apply(st, cur, d->>'a', (d->>'amt')::numeric); changed := true; else exit; end if;
    else
      if (st->>'deadline') is not null and (st->>'deadline')::timestamptz <= now() then L := public.pk_legal(st, cur); st := public.pk_apply(st, cur, case when (L->>'check')::boolean then 'check' else 'fold' end, 0); changed := true; else exit; end if;
    end if;
  end loop;
  -- el bitti / boşta: yeni el
  if st->>'phase' in ('done','idle') then
    -- ayrılmış (leaving) ve 2 dakikadır sessiz insanlar koltuktan kalkar
    for i in 0..2 loop s := public.pk_sget(st, i); if s is null or jsonb_typeof(s) <> 'object' then continue; end if;
      if (s->>'leaving')::boolean then st := jsonb_set(st, array['seats', i::text], 'null'); changed := true;
      elsif not (s->>'bot')::boolean and not exists (select 1 from public.pk_presence p where p.user_id = (s->>'user')::uuid and p.seen > now() - interval '120 seconds') then
        perform public.bj_pay((s->>'user')::uuid, (s->>'stack')::numeric); st := jsonb_set(st, array['seats', i::text], 'null'); changed := true;
      end if;
    end loop;
    st := public.pk_fill_bots(st);
    if public.pk_humans(st) = 0 then
      if st->>'phase' <> 'idle' then st := jsonb_set(public.pk_empty_state(), '{hand}', st->'hand'); changed := true; end if;
    elsif (st->>'nextAt') is not null and (st->>'nextAt')::timestamptz <= now() then
      st := public.pk_start_hand(st); changed := true;
    end if;
  end if;
  if changed then perform public.pk_save(st); end if;
  return st;
end $$;
grant execute on function public.pk_tick() to authenticated;

do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='pk_table') then
    alter publication supabase_realtime add table public.pk_table;
  end if;
end $$;
update public.pk_table set state = public.pk_empty_state() where id = 1 and state = '{}'::jsonb;
