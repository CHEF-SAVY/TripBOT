-- Resizes the access limiter for what it now guards.
--
-- It was written when /api/live/access checked a secret, where eight attempts per quarter
-- hour is a sensible ceiling on guessing. That endpoint now issues the visitor identity the
-- tour limiter and session tokens bind to, and issuing is idempotent for anyone who already
-- holds a valid cookie — so the only callers this counts are genuinely new visitors from an
-- address. Eight of those is easy to exhaust from a shared or NAT'd network, and a judge who
-- reloaded a few times would be locked out of a demo that has no other door.
--
-- Thirty still bounds automated abuse, while the real protection against draining the wallet
-- remains where it always was: the per-IP tour limit, the preflight balance floors, and the
-- IP-bound quote and session tokens.

create or replace function public.claim_demo_access_attempt(p_ip_hash text) returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare allowed boolean;
begin
  if length(p_ip_hash) <> 64 then raise exception 'invalid access attempt'; end if;
  perform pg_advisory_xact_lock(hashtext('tripbot-demo-access:' || p_ip_hash));
  select count(*) < 30 into allowed
  from public.demo_access_attempts
  where ip_hash = p_ip_hash and created_at > now() - interval '15 minutes';
  if allowed then
    insert into public.demo_access_attempts(ip_hash) values (p_ip_hash);
  end if;
  return allowed;
end;
$$;

revoke all on function public.claim_demo_access_attempt(text) from public, anon, authenticated;
grant execute on function public.claim_demo_access_attempt(text) to service_role;
