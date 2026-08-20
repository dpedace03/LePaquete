-- ============================================================================
--  El Almacén — Fase 2: Auth de staff + perfiles + RLS por rol + Realtime
--  Correr DESPUÉS del primer SQL. Es re-ejecutable.
--  Supabase → SQL Editor → Run.
-- ============================================================================

-- ---------- Perfiles ligados a auth.users ----------
create table if not exists perfiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  nombre     text,
  rol        text not null default 'cliente' check (rol in ('admin','empleado','cliente')),
  tel        text,
  created_at timestamptz default now()
);
alter table perfiles enable row level security;

-- ---------- Helpers de rol (SECURITY DEFINER: evitan recursión de RLS) ----------
create or replace function is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from perfiles where id = auth.uid() and rol in ('admin','empleado'));
$$;
create or replace function is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from perfiles where id = auth.uid() and rol = 'admin');
$$;

-- ---------- Policies de perfiles ----------
drop policy if exists perfil_propio on perfiles;
drop policy if exists perfil_update on perfiles;
drop policy if exists perfil_staff  on perfiles;
create policy perfil_propio on perfiles for select using (id = auth.uid() or is_staff());
create policy perfil_update on perfiles for update using (id = auth.uid()) with check (id = auth.uid());
create policy perfil_staff  on perfiles for all    using (is_staff()) with check (is_staff());

-- ---------- Crear perfil automáticamente al registrarse un usuario ----------
create or replace function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into perfiles(id, nombre, rol, tel)
  values (new.id,
          coalesce(new.raw_user_meta_data->>'nombre', new.email),
          'cliente',
          new.raw_user_meta_data->>'tel')
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function handle_new_user();

-- ---------- Vincular pedidos al usuario que los crea (historial del cliente) ----------
alter table pedidos add column if not exists cliente_uid uuid references auth.users(id);

-- ---------- crear_pedido: ahora guarda cliente_uid = quien llama (si está logueado) ----------
create or replace function crear_pedido(
  p_nombre text, p_tel text, p_dir text,
  p_tipo text, p_pago text, p_nota text, p_items jsonb
) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_n bigint; v_estado text; v_envio numeric := 0; v_total numeric := 0; it jsonb;
begin
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'El pedido no tiene items';
  end if;
  select id into v_estado from estados_pedido order by orden asc, id asc limit 1;
  select coalesce(costo,0) into v_envio from tipos_envio where id = p_tipo;
  select coalesce(sum((i->>'precio')::numeric * (i->>'qty')::numeric),0)
    into v_total from jsonb_array_elements(p_items) i;
  v_total := v_total + coalesce(v_envio,0);

  insert into pedidos(cliente_nombre,cliente_tel,cliente_dir,tipo,pago,estado,nota,envio_costo,total,cliente_uid)
  values (p_nombre,p_tel,p_dir,p_tipo,p_pago,v_estado,p_nota,coalesce(v_envio,0),v_total,auth.uid())
  returning n into v_n;

  for it in select * from jsonb_array_elements(p_items) loop
    insert into pedido_items(pedido_n,producto_id,nombre,unidad,precio,qty,es_promo)
    values (v_n, it->>'producto_id', it->>'nombre', coalesce(it->>'unidad','un'),
            (it->>'precio')::numeric, (it->>'qty')::numeric, coalesce((it->>'es_promo')::boolean,false));
  end loop;

  if p_tel is not null and length(trim(p_tel)) > 0 then
    if exists (select 1 from clientes where tel = p_tel) then
      update clientes set nombre = coalesce(nullif(p_nombre,''), nombre),
                          dir    = coalesce(nullif(p_dir,''), dir)
        where tel = p_tel;
    else
      insert into clientes(nombre,tel,dir) values (p_nombre,p_tel,p_dir);
    end if;
  end if;
  return v_n;
end $$;
grant execute on function crear_pedido(text,text,text,text,text,text,jsonb) to anon, authenticated;

-- ============================================================================
--  RLS: gestión pasa de "cualquier authenticated" a SOLO staff (is_staff())
--  (la lectura pública del escaparate se mantiene)
-- ============================================================================
drop policy if exists admin_config     on config;
drop policy if exists admin_categorias on categorias;
drop policy if exists admin_pagos      on formas_pago;
drop policy if exists admin_envios     on tipos_envio;
drop policy if exists admin_estados    on estados_pedido;
drop policy if exists admin_productos  on productos;
drop policy if exists admin_promos     on promos;
drop policy if exists admin_promoitems on promo_items;
drop policy if exists admin_clientes   on clientes;
drop policy if exists admin_usuarios   on usuarios;
drop policy if exists admin_pedidos    on pedidos;
drop policy if exists admin_pitems     on pedido_items;

create policy staff_config     on config         for all using (is_staff()) with check (is_staff());
create policy staff_categorias on categorias     for all using (is_staff()) with check (is_staff());
create policy staff_pagos      on formas_pago    for all using (is_staff()) with check (is_staff());
create policy staff_envios     on tipos_envio    for all using (is_staff()) with check (is_staff());
create policy staff_estados    on estados_pedido for all using (is_staff()) with check (is_staff());
create policy staff_productos  on productos      for all using (is_staff()) with check (is_staff());
create policy staff_promos     on promos         for all using (is_staff()) with check (is_staff());
create policy staff_promoitems on promo_items    for all using (is_staff()) with check (is_staff());
create policy staff_clientes   on clientes       for all using (is_staff()) with check (is_staff());
create policy staff_usuarios   on usuarios       for all using (is_staff()) with check (is_staff());

-- Pedidos: staff ve/gestiona todo; el cliente ve SOLO los suyos
create policy staff_pedidos       on pedidos       for all    using (is_staff()) with check (is_staff());
create policy cliente_pedidos     on pedidos       for select using (cliente_uid = auth.uid());
create policy staff_pedido_items  on pedido_items  for all    using (is_staff()) with check (is_staff());
create policy cliente_pedido_items on pedido_items for select using (
  exists (select 1 from pedidos p where p.n = pedido_items.pedido_n and p.cliente_uid = auth.uid())
);

-- ---------- Realtime en pedidos (panel en vivo) ----------
do $$
begin
  begin
    alter publication supabase_realtime add table pedidos;
  exception when duplicate_object then null;
  end;
end $$;

-- ============================================================================
--  PASO MANUAL (una sola vez): crear tu usuario y hacerlo admin
--    1) Authentication → Users → "Add user" → email + contraseña (Auto Confirm).
--    2) Ejecutá esto cambiando el email:
--       update perfiles set rol = 'admin'
--         where id = (select id from auth.users where email = 'vos@correo.com');
--    (Para un empleado, usá rol = 'empleado'.)
-- ============================================================================
