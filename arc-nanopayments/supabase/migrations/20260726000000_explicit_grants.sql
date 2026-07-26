-- The original migrations rely on Supabase's default privileges for the API roles,
-- which did not apply on a fresh local stack (service_role lacked INSERT), so the
-- seller's payment-event recording failed with "permission denied". Grant explicitly.
grant usage on schema public to anon, authenticated, service_role;

grant select on public.payment_events, public.withdrawals to anon, authenticated, service_role;
grant insert on public.payment_events, public.withdrawals to service_role;
grant update on public.withdrawals to service_role;
