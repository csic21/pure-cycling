-- handle_new_user is a trigger helper, never a client RPC. Restrict EXECUTE
-- after creating its trigger so PostgREST cannot expose this SECURITY DEFINER
-- function to anonymous or signed-in clients.
revoke execute on function public.handle_new_user()
  from public, anon, authenticated;

-- Auth inserts into auth.users through this role. Keep its trigger path valid.
grant execute on function public.handle_new_user()
  to supabase_auth_admin;
