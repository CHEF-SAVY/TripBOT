-- Durable serialization for the three server-side signing roles.
--
-- The application previously serialized signer access with an in-process promise
-- chain. That holds only within a single Node instance, which is exactly what a
-- serverless deployment does not guarantee: two concurrent judge sessions can be
-- routed to different instances, both read the same pending nonce, and one
-- transaction is then dropped or replaced. Nonce ordering has to be enforced
-- somewhere both instances can see, so it lives here.
--
-- A lease is a row per role, held by a random holder token, with an absolute
-- expiry so a crashed or timed-out instance cannot wedge a role permanently.

create table if not exists public.signer_leases (
  role text primary key check (role in ('buyer', 'seller', 'arbiter')),
  holder uuid not null,
  acquired_at timestamptz not null default now(),
  expires_at timestamptz not null
);

alter table public.signer_leases enable row level security;

grant all on table public.signer_leases to service_role;

-- Grants the lease if it is unheld or expired, and is a no-op otherwise. The
-- insert/update is a single statement so two callers racing on the same role
-- cannot both observe a free lease: the primary key serializes them, and the
-- where clause makes the loser's update affect zero rows.
create or replace function public.claim_signer_lease(
  p_role text,
  p_holder uuid,
  p_ttl_seconds integer
) returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_claimed boolean;
begin
  if p_ttl_seconds is null or p_ttl_seconds <= 0 or p_ttl_seconds > 600 then
    raise exception 'ttl out of range';
  end if;

  insert into public.signer_leases as l (role, holder, acquired_at, expires_at)
  values (p_role, p_holder, now(), now() + make_interval(secs => p_ttl_seconds))
  on conflict (role) do update
    set holder = excluded.holder,
        acquired_at = excluded.acquired_at,
        expires_at = excluded.expires_at
    where l.expires_at <= now()
  returning true into v_claimed;

  return coalesce(v_claimed, false);
end;
$$;

-- Releasing requires proving you are the current holder, so a slow caller whose
-- lease already expired and was taken by someone else cannot release the new
-- holder's lease out from under them.
create or replace function public.release_signer_lease(
  p_role text,
  p_holder uuid
) returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_released boolean;
begin
  delete from public.signer_leases
  where role = p_role and holder = p_holder
  returning true into v_released;

  return coalesce(v_released, false);
end;
$$;

grant execute on function public.claim_signer_lease(text, uuid, integer) to service_role;
grant execute on function public.release_signer_lease(text, uuid) to service_role;
