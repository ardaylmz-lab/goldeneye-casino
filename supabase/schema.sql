-- Golden Eye Casino · Supabase şeması (Faz 1: hesaplar, profiller, ortak bakiye)
-- Supabase Dashboard → SQL Editor → yapıştır → Run. Tekrar çalıştırmak güvenlidir.

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  name text not null default 'Oyuncu',
  balance numeric(12,2) not null default 20000,
  avatar_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

drop policy if exists "profiles: herkes okur" on public.profiles;
create policy "profiles: herkes okur" on public.profiles
  for select to authenticated using (true);

drop policy if exists "profiles: kendi satırını günceller" on public.profiles;
create policy "profiles: kendi satırını günceller" on public.profiles
  for update to authenticated using (auth.uid() = id) with check (auth.uid() = id);

-- Yeni kullanıcı kaydolunca profil otomatik açılır (ad: kayıt formundaki ad, yoksa e-postanın başı)
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, name)
  values (new.id, coalesce(nullif(new.raw_user_meta_data->>'name',''), split_part(new.email,'@',1)))
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users for each row execute function public.handle_new_user();

-- Bakiye yazma: istemci yalnız bu fonksiyonla kendi bakiyesini günceller
create or replace function public.set_balance(new_balance numeric)
returns numeric language plpgsql security definer set search_path = public as $$
declare b numeric;
begin
  if auth.uid() is null then raise exception 'oturum yok'; end if;
  update public.profiles
     set balance = greatest(0, round(new_balance, 2)), updated_at = now()
   where id = auth.uid()
  returning balance into b;
  return b;
end $$;
grant execute on function public.set_balance(numeric) to authenticated;

-- Ad / avatar güncelleme
create or replace function public.set_profile(p_name text default null, p_avatar text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'oturum yok'; end if;
  update public.profiles
     set name = coalesce(nullif(trim(p_name),''), name),
         avatar_url = coalesce(p_avatar, avatar_url),
         updated_at = now()
   where id = auth.uid();
end $$;
grant execute on function public.set_profile(text, text) to authenticated;

-- Realtime: profil değişiklikleri cihazlara anında düşsün
do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='profiles') then
    alter publication supabase_realtime add table public.profiles;
  end if;
end $$;
