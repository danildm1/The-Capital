-- THE CAPITAL: схема базы данных для продаж и выдачи материалов (Supabase / PostgreSQL).
-- Запускать целиком в SQL Editor. ВАЖНО: этот файл не исполнялся в проверочной среде (там нет PostgreSQL);
-- выполните его сначала в тестовом проекте Supabase и пройдите чек-лист из docs/ARCHITECTURE.md.
--
-- Принципы:
--  * цены и состав заказа определяет только сервер по таблице products (браузеру не доверяем);
--  * деньги хранятся целыми центами;
--  * каждое событие провайдера записывается один раз (unique provider+event_id), обработка идемпотентна;
--  * доступ к материалам даёт только запись в entitlements, а её создаёт только функция mark_order_paid;
--  * всё закрыто RLS; серверные функции вызываются ключом service_role на сервере (Vercel), не в браузере.

create extension if not exists citext;

-- ---------------------------------------------------------------- каталог
create table if not exists public.products (
  id            uuid primary key default gen_random_uuid(),
  slug          text not null unique check (slug ~ '^[a-z0-9-]{2,40}$'),
  kind          text not null check (kind in ('single', 'bundle')),
  title         text not null,
  direction_no  smallint,
  price_cents   integer not null check (price_cents >= 0),
  currency      text not null default 'USD' check (currency = upper(currency)),
  active        boolean not null default true,
  sort_order    smallint not null default 0,
  created_at    timestamptz not null default now()
);

create table if not exists public.bundle_items (
  bundle_id   uuid not null references public.products(id) on delete cascade,
  product_id  uuid not null references public.products(id) on delete restrict,
  primary key (bundle_id, product_id)
);

-- ---------------------------------------------------------------- заказы
create table if not exists public.orders (
  id                   uuid primary key default gen_random_uuid(),
  email                citext not null,
  status               text not null default 'pending'
                       check (status in ('pending', 'paid', 'expired', 'failed', 'refunded')),
  total_cents          integer not null check (total_cents >= 0),
  currency             text not null default 'USD',
  provider             text not null default 'usdpay',
  provider_invoice_id  text,
  idempotency_key      text unique,
  created_at           timestamptz not null default now(),
  expires_at           timestamptz,
  paid_at              timestamptz,
  unique (provider, provider_invoice_id)
);
create index if not exists orders_email_idx on public.orders (email);
create index if not exists orders_status_idx on public.orders (status, created_at);

create table if not exists public.order_items (
  id               uuid primary key default gen_random_uuid(),
  order_id         uuid not null references public.orders(id) on delete cascade,
  product_id       uuid not null references public.products(id),
  unit_price_cents integer not null check (unit_price_cents >= 0),
  unique (order_id, product_id)
);

-- Журнал событий платёжного провайдера. Одно событие записывается один раз.
create table if not exists public.payment_events (
  id               uuid primary key default gen_random_uuid(),
  provider         text not null,
  event_id         text not null,
  order_id         uuid references public.orders(id),
  signature_valid  boolean not null,
  payload          jsonb not null,
  received_at      timestamptz not null default now(),
  processed_at     timestamptz,
  process_error    text,
  unique (provider, event_id)
);

-- ---------------------------------------------------------------- доступ и материалы
create table if not exists public.entitlements (
  id          uuid primary key default gen_random_uuid(),
  email       citext not null,
  product_id  uuid not null references public.products(id),
  order_id    uuid not null references public.orders(id),
  granted_at  timestamptz not null default now(),
  revoked_at  timestamptz,
  unique (email, product_id)
);
create index if not exists entitlements_email_idx on public.entitlements (email);

create table if not exists public.materials (
  id            uuid primary key default gen_random_uuid(),
  product_id    uuid not null references public.products(id),
  title         text not null,
  storage_path  text not null,            -- путь в закрытом bucket "materials"
  version       integer not null default 1,
  published     boolean not null default false,
  created_at    timestamptz not null default now(),
  unique (product_id, version)
);

-- ---------------------------------------------------------------- безопасность строк (RLS)
alter table public.products       enable row level security;
alter table public.bundle_items   enable row level security;
alter table public.orders         enable row level security;
alter table public.order_items    enable row level security;
alter table public.payment_events enable row level security;
alter table public.entitlements   enable row level security;
alter table public.materials      enable row level security;

-- Каталог можно читать всем (это публичная витрина).
drop policy if exists products_read on public.products;
create policy products_read on public.products for select using (active);
drop policy if exists bundle_items_read on public.bundle_items;
create policy bundle_items_read on public.bundle_items for select using (true);

-- Пользователь видит только свои права доступа (по email из подтверждённого входа).
drop policy if exists entitlements_own on public.entitlements;
create policy entitlements_own on public.entitlements for select
  using (revoked_at is null and email = lower(coalesce(auth.jwt() ->> 'email', ''))::citext);

-- orders, order_items, payment_events, materials: политик нет, значит доступ только у service_role (сервер).

-- ---------------------------------------------------------------- серверные функции
-- Создать заказ. Цены берутся из таблицы products, а не от браузера. Возвращает id заказа.
create or replace function public.create_order(p_email citext, p_slugs text[], p_idem text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_existing uuid;
  v_order    uuid;
  v_count    integer;
  v_bundles  integer;
  v_total    integer;
begin
  if p_slugs is null or array_length(p_slugs, 1) is null then
    raise exception 'empty_order';
  end if;

  if p_idem is not null then
    select id into v_existing from orders where idempotency_key = p_idem;
    if found then return v_existing; end if;
  end if;

  select count(*), count(*) filter (where kind = 'bundle'), coalesce(sum(price_cents), 0)
    into v_count, v_bundles, v_total
    from products
   where slug = any (select distinct unnest(p_slugs)) and active;

  if v_count <> (select count(distinct s) from unnest(p_slugs) s) then
    raise exception 'unknown_or_inactive_product';
  end if;
  -- Комплект нельзя сочетать с отдельными направлениями: иначе человек заплатит дважды за одно и то же.
  if v_bundles > 0 and v_count > 1 then
    raise exception 'bundle_with_singles';
  end if;

  insert into orders (email, total_cents, idempotency_key, expires_at)
  values (lower(p_email)::citext, v_total, p_idem, now() + interval '2 hours')
  returning id into v_order;

  insert into order_items (order_id, product_id, unit_price_cents)
  select v_order, id, price_cents from products where slug = any (select distinct unnest(p_slugs)) and active;

  return v_order;
end;
$$;

-- Подтвердить оплату и выдать доступ. Безопасно вызывать повторно (идемпотентно).
-- p_paid_cents: сумма, подтверждённая провайдером (сервер сверяет её с провайдером, а не берёт из браузера).
create or replace function public.mark_order_paid(p_order_id uuid, p_paid_cents integer)
returns table (granted integer, already_paid boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order   orders%rowtype;
  v_granted integer := 0;
begin
  select * into v_order from orders where id = p_order_id for update;
  if not found then raise exception 'order_not_found'; end if;

  if v_order.status = 'paid' then
    return query select 0, true;
    return;
  end if;
  if v_order.status not in ('pending', 'expired') then
    raise exception 'order_not_payable: %', v_order.status;
  end if;
  if p_paid_cents < v_order.total_cents then
    raise exception 'underpaid';
  end if;

  update orders set status = 'paid', paid_at = now() where id = p_order_id;

  insert into entitlements (email, product_id, order_id)
  select v_order.email, x.product_id, p_order_id
  from (
    select oi.product_id
      from order_items oi join products p on p.id = oi.product_id
     where oi.order_id = p_order_id and p.kind = 'single'
    union
    select bi.product_id
      from order_items oi
      join products p on p.id = oi.product_id and p.kind = 'bundle'
      join bundle_items bi on bi.bundle_id = p.id
     where oi.order_id = p_order_id
  ) x
  on conflict (email, product_id) do nothing;
  get diagnostics v_granted = row_count;

  return query select v_granted, false;
end;
$$;

revoke all on function public.create_order(citext, text[], text) from public, anon, authenticated;
revoke all on function public.mark_order_paid(uuid, integer)     from public, anon, authenticated;
grant execute on function public.create_order(citext, text[], text) to service_role;
grant execute on function public.mark_order_paid(uuid, integer)     to service_role;

-- ---------------------------------------------------------------- начальные данные
insert into public.products (slug, kind, title, direction_no, price_cents, sort_order) values
  ('foundations', 'single', 'THE FOUNDATIONS', 1, 200, 1),
  ('business',    'single', 'THE BUSINESS',    2, 200, 2),
  ('capital',     'single', 'THE CAPITAL',     3, 200, 3),
  ('casefiles',   'single', 'THE CASE FILES',  4, 200, 4),
  ('playbook',    'single', 'THE PLAYBOOK',    5, 200, 5),
  ('all',         'bundle', 'Все пять направлений', null, 800, 10)
on conflict (slug) do update set title = excluded.title, price_cents = excluded.price_cents;

insert into public.bundle_items (bundle_id, product_id)
select b.id, p.id from public.products b join public.products p on p.kind = 'single'
 where b.slug = 'all'
on conflict do nothing;

-- Закрытое хранилище материалов (файлы отдаются сервером по временным ссылкам).
insert into storage.buckets (id, name, public) values ('materials', 'materials', false)
on conflict (id) do nothing;
