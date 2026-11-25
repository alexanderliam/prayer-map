-- Prayer Map: database setup for shared check-ins (Supabase / Postgres).
-- Run once in the SQL editor of a new project. Also switch on "Anonymous sign-ins" in the project's sign-in settings.

create table public.checkins (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() unique,          -- one light per visitor
  lat double precision not null check (lat between -85 and 85),   -- already moved up to ~20 miles on the visitor's device
  lon double precision not null check (lon between -180 and 180),
  prayer smallint not null check (prayer between 0 and 5),
  intention text check (intention is null or (char_length(intention) <= 140
    and intention !~* '(https?://|www\.|fuck|shit|cunt|bitch|bastard|wank)')),
  event text check (event is null or char_length(event) <= 40),
  hearts integer not null default 0,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '20 minutes'
);

create table public.hearts (
  checkin_id uuid not null references public.checkins(id) on delete cascade,
  user_id uuid not null,
  n integer not null default 0,
  primary key (checkin_id, user_id)
);

create table public.reports (
  checkin_id uuid not null references public.checkins(id) on delete cascade,
  user_id uuid not null,
  primary key (checkin_id, user_id)
);

alter table public.checkins enable row level security;
alter table public.hearts enable row level security;    -- no rules: only the functions below touch it
alter table public.reports enable row level security;   -- no rules: only the functions below touch it

-- Visitors may read every light, add their own, and remove their own. They cannot set hearts or expiry themselves.
revoke all on public.checkins from anon, authenticated;
grant select on public.checkins to anon, authenticated;
grant insert (id, lat, lon, prayer, intention, event) on public.checkins to authenticated;
grant delete on public.checkins to authenticated;
revoke all on public.hearts, public.reports from anon, authenticated;

create policy "anyone can read" on public.checkins for select using (true);
create policy "add your own" on public.checkins for insert to authenticated with check (user_id = auth.uid());
create policy "remove your own" on public.checkins for delete to authenticated using (user_id = auth.uid());

-- Send one heart (at most 20 from one visitor to one light; none to yourself).
create or replace function public.send_heart(target uuid) returns void
language plpgsql security definer set search_path = public as $$
declare cur integer;
begin
  if auth.uid() is null then return; end if;
  if exists (select 1 from checkins c where c.id = target and c.user_id = auth.uid()) then return; end if;
  insert into hearts as h (checkin_id, user_id, n) values (target, auth.uid(), 1)
    on conflict (checkin_id, user_id) do update set n = h.n + 1 where h.n < 20
    returning h.n into cur;
  if cur is not null then update checkins c set hearts = c.hearts + 1 where c.id = target; end if;
end $$;

-- Take back every heart you sent to one light.
create or replace function public.take_back_hearts(target uuid) returns void
language plpgsql security definer set search_path = public as $$
declare cur integer;
begin
  delete from hearts h where h.checkin_id = target and h.user_id = auth.uid() returning h.n into cur;
  if cur is not null then update checkins c set hearts = greatest(0, c.hearts - cur) where c.id = target; end if;
end $$;

-- Report a light. Three reports from different visitors remove it for everyone.
create or replace function public.report_checkin(target uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return; end if;
  insert into reports (checkin_id, user_id) values (target, auth.uid()) on conflict do nothing;
  if (select count(*) from reports r where r.checkin_id = target) >= 3 then
    delete from checkins c where c.id = target;
  end if;
end $$;

-- Called every few minutes while someone is still praying; also clears lights whose time has run out.
create or replace function public.keep_alive() returns void
language plpgsql security definer set search_path = public as $$
begin
  update checkins c set expires_at = now() + interval '20 minutes' where c.user_id = auth.uid();
  delete from checkins c where c.expires_at < now();
end $$;

revoke execute on function public.send_heart(uuid), public.take_back_hearts(uuid), public.report_checkin(uuid), public.keep_alive() from public, anon;
grant execute on function public.send_heart(uuid), public.take_back_hearts(uuid), public.report_checkin(uuid), public.keep_alive() to authenticated;

-- Send live changes to everyone who has the map open.
alter publication supabase_realtime add table public.checkins;
