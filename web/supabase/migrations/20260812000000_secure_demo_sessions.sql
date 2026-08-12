create table if not exists public.demo_tour_claims (
  id bigint generated always as identity primary key,
  visitor_hash text not null check (length(visitor_hash) = 64),
  ip_hash text not null check (length(ip_hash) = 64),
  seller_key text not null check (seller_key in ('honest', 'faulty', 'absent')),
  created_at timestamptz not null default now()
);

create table if not exists public.demo_access_attempts (
  id bigint generated always as identity primary key,
  ip_hash text not null check (length(ip_hash) = 64),
  created_at timestamptz not null default now()
);

create index if not exists demo_tour_claims_created_at_idx on public.demo_tour_claims (created_at);
create index if not exists demo_tour_claims_binding_idx
  on public.demo_tour_claims (visitor_hash, ip_hash, seller_key, created_at desc);
create index if not exists demo_access_attempts_ip_idx
  on public.demo_access_attempts (ip_hash, created_at desc);

create table if not exists public.demo_quotes (
  nonce uuid primary key,
  visitor_hash text not null check (length(visitor_hash) = 64),
  ip_hash text not null check (length(ip_hash) = 64),
  seller_key text not null check (seller_key in ('honest', 'faulty', 'absent')),
  request_hash text not null check (request_hash ~ '^0x[0-9a-fA-F]{64}$'),
  validation_tx_hash text not null check (validation_tx_hash ~ '^0x[0-9a-fA-F]{64}$'),
  price_wei text not null check (price_wei ~ '^[0-9]{1,78}$' and price_wei !~ '^0+$'),
  seller_agent_id text not null check (seller_agent_id ~ '^[0-9]{1,78}$'),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  consumed_at timestamptz,
  check (expires_at > created_at)
);

create table if not exists public.demo_sessions (
  id uuid primary key,
  quote_nonce uuid not null unique references public.demo_quotes(nonce),
  visitor_hash text not null check (length(visitor_hash) = 64),
  ip_hash text not null check (length(ip_hash) = 64),
  seller_key text not null check (seller_key in ('honest', 'faulty', 'absent')),
  job_id text check (job_id is null or job_id ~ '^[0-9]{1,78}$'),
  evidence_hash text check (evidence_hash is null or evidence_hash ~ '^0x[0-9a-fA-F]{64}$'),
  evidence jsonb,
  create_tx_hash text check (create_tx_hash is null or create_tx_hash ~ '^0x[0-9a-fA-F]{64}$'),
  evidence_tx_hash text check (evidence_tx_hash is null or evidence_tx_hash ~ '^0x[0-9a-fA-F]{64}$'),
  verdict text check (verdict is null or verdict in ('accept', 'dispute')),
  verdict_tx_hash text check (verdict_tx_hash is null or verdict_tx_hash ~ '^0x[0-9a-fA-F]{64}$'),
  resolved_at timestamptz,
  state text not null default 'funding' check (state in ('funding', 'delivered', 'settling', 'settled', 'resolving', 'resolved', 'failed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  expires_at timestamptz not null,
  unique (job_id)
);

create table if not exists public.job_deliveries (
  job_key text primary key check (length(job_key) between 3 and 160),
  job_id text not null check (job_id ~ '^[0-9]{1,78}$'),
  escrow_address text not null check (escrow_address ~ '^0x[0-9a-fA-F]{40}$'),
  endpoint text not null check (length(endpoint) between 1 and 256),
  buyer text not null check (buyer ~ '^0x[0-9a-fA-F]{40}$'),
  delivered_at timestamptz not null default now()
);

alter table public.demo_tour_claims enable row level security;
alter table public.demo_access_attempts enable row level security;
alter table public.demo_quotes enable row level security;
alter table public.demo_sessions enable row level security;
alter table public.job_deliveries enable row level security;

revoke all on table public.demo_tour_claims from anon, authenticated;
revoke all on table public.demo_access_attempts from anon, authenticated;
revoke all on table public.demo_quotes from anon, authenticated;
revoke all on table public.demo_sessions from anon, authenticated;
revoke all on table public.job_deliveries from anon, authenticated;
grant all on table public.demo_tour_claims to service_role;
grant all on table public.demo_access_attempts to service_role;
grant all on table public.demo_quotes to service_role;
grant all on table public.demo_sessions to service_role;
grant all on table public.job_deliveries to service_role;
grant usage, select on sequence public.demo_tour_claims_id_seq to service_role;
grant usage, select on sequence public.demo_access_attempts_id_seq to service_role;

create or replace function public.claim_demo_access_attempt(p_ip_hash text) returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare allowed boolean;
begin
  if length(p_ip_hash) <> 64 then raise exception 'invalid access attempt'; end if;
  perform pg_advisory_xact_lock(hashtext('tripbot-demo-access:' || p_ip_hash));
  select count(*) < 8 into allowed
  from public.demo_access_attempts
  where ip_hash = p_ip_hash and created_at > now() - interval '15 minutes';
  if allowed then
    insert into public.demo_access_attempts(ip_hash) values (p_ip_hash);
  end if;
  return allowed;
end;
$$;

create or replace function public.claim_demo_tour(
  p_visitor_hash text,
  p_ip_hash text,
  p_seller_key text
) returns table(result text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if length(p_visitor_hash) <> 64 or length(p_ip_hash) <> 64
     or p_seller_key not in ('honest', 'faulty', 'absent') then
    raise exception 'invalid tour claim';
  end if;
  perform pg_advisory_xact_lock(hashtext('tripbot-demo-tour-capacity'));
  if exists (
    select 1 from public.demo_tour_claims
    where visitor_hash = p_visitor_hash and ip_hash = p_ip_hash and seller_key = p_seller_key
      and created_at > now() - interval '5 minutes'
  ) then
    return query select 'already_ran'::text;
    return;
  end if;
  if (select count(*) from public.demo_tour_claims where created_at > now() - interval '1 hour') >= 20 then
    return query select 'capacity'::text;
    return;
  end if;
  insert into public.demo_tour_claims(visitor_hash, ip_hash, seller_key)
  values (p_visitor_hash, p_ip_hash, p_seller_key);
  return query select 'claimed'::text;
end;
$$;

create or replace function public.consume_demo_quote(
  p_nonce uuid,
  p_visitor_hash text,
  p_ip_hash text
) returns setof public.demo_quotes
language sql
security definer
set search_path = public, pg_temp
as $$
  update public.demo_quotes
  set consumed_at = now()
  where nonce = p_nonce
    and visitor_hash = p_visitor_hash
    and ip_hash = p_ip_hash
    and consumed_at is null
    and expires_at > now()
  returning *;
$$;

create or replace function public.claim_demo_verdict(
  p_id uuid,
  p_visitor_hash text,
  p_ip_hash text,
  p_verdict text
) returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare claimed integer;
begin
  if p_verdict not in ('accept', 'dispute') then raise exception 'invalid verdict'; end if;
  update public.demo_sessions
  set state = 'settling', verdict = p_verdict, updated_at = now()
  where id = p_id and visitor_hash = p_visitor_hash and ip_hash = p_ip_hash and state = 'delivered';
  get diagnostics claimed = row_count;
  return claimed = 1;
end;
$$;

create or replace function public.claim_demo_resolution(
  p_id uuid,
  p_visitor_hash text,
  p_ip_hash text
) returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare claimed integer;
begin
  update public.demo_sessions
  set state = 'resolving', updated_at = now()
  where id = p_id and visitor_hash = p_visitor_hash and ip_hash = p_ip_hash
    and state = 'settled' and verdict = 'dispute';
  get diagnostics claimed = row_count;
  return claimed = 1;
end;
$$;

revoke all on function public.claim_demo_tour(text, text, text) from public, anon, authenticated;
revoke all on function public.claim_demo_access_attempt(text) from public, anon, authenticated;
revoke all on function public.consume_demo_quote(uuid, text, text) from public, anon, authenticated;
revoke all on function public.claim_demo_verdict(uuid, text, text, text) from public, anon, authenticated;
revoke all on function public.claim_demo_resolution(uuid, text, text) from public, anon, authenticated;
grant execute on function public.claim_demo_tour(text, text, text) to service_role;
grant execute on function public.claim_demo_access_attempt(text) to service_role;
grant execute on function public.consume_demo_quote(uuid, text, text) to service_role;
grant execute on function public.claim_demo_verdict(uuid, text, text, text) to service_role;
grant execute on function public.claim_demo_resolution(uuid, text, text) to service_role;
