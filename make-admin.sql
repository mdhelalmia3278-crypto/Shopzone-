-- Replace the email below with the exact email you registered with.
-- Run this only in your own Supabase SQL Editor.
update public.profiles p
set role = 'admin'
from auth.users u
where p.id = u.id
  and lower(u.email) = lower('YOUR-REGISTERED-EMAIL@example.com');

-- Verify: this should return your user and role=admin.
select u.email, p.role
from auth.users u
join public.profiles p on p.id = u.id
where lower(u.email) = lower('YOUR-REGISTERED-EMAIL@example.com');
