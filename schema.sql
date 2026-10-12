-- Run in Supabase SQL Editor. This schema enforces access with RLS.
create extension if not exists pgcrypto;

create type public.user_role as enum ('customer','admin');
create type public.order_status as enum ('নতুন','প্রসেসিং','শিপড','ডেলিভারড','বাতিল');

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null default '',
  role public.user_role not null default 'customer',
  created_at timestamptz not null default now()
);

create function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  insert into public.profiles(id, full_name)
  values (new.id, coalesce(new.raw_user_meta_data->>'full_name',''));
  return new;
end;
$$;

create trigger on_auth_user_created
after insert on auth.users
for each row execute procedure public.handle_new_user();

create table public.products (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 180),
  category text not null default 'অন্যান্য',
  description text not null default '',
  image_url text not null default '',
  price numeric(12,2) not null check (price > 0),
  stock integer not null default 0 check (stock >= 0),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.orders (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id),
  customer_name text not null,
  phone text not null,
  address text not null,
  city text not null,
  payment_method text not null check (payment_method in ('cod','manual')),
  transaction_ref text,
  payment_status text not null default 'unpaid' check (payment_status in ('unpaid','pending_verification','paid','refunded')),
  status public.order_status not null default 'নতুন',
  subtotal numeric(12,2) not null check (subtotal >= 0),
  shipping_fee numeric(12,2) not null check (shipping_fee >= 0),
  total numeric(12,2) not null check (total >= 0),
  created_at timestamptz not null default now()
);

create table public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  product_id uuid references public.products(id) on delete set null,
  product_name text not null,
  unit_price numeric(12,2) not null check (unit_price > 0),
  quantity integer not null check (quantity > 0),
  created_at timestamptz not null default now()
);

create index products_active_created_idx on public.products(active, created_at desc);
create index orders_user_created_idx on public.orders(user_id, created_at desc);
create index order_items_order_idx on public.order_items(order_id);

alter table public.profiles enable row level security;
alter table public.products enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;

create function public.is_admin()
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists(select 1 from public.profiles p where p.id = (select auth.uid()) and p.role = 'admin');
$$;
revoke all on function public.is_admin() from public;
grant execute on function public.is_admin() to authenticated, anon;

create policy "Users can read own profile or admins read all"
on public.profiles for select to authenticated
using (id = (select auth.uid()) or public.is_admin());
create policy "Users can update own name only via limited app" on public.profiles
for update to authenticated using (id = (select auth.uid())) with check (id = (select auth.uid()) and role = 'customer');
create policy "Admins can manage profiles" on public.profiles
for all to authenticated using (public.is_admin()) with check (public.is_admin());

create policy "Anyone can view active products"
on public.products for select to anon, authenticated using (active = true or public.is_admin());
create policy "Admins insert products" on public.products
for insert to authenticated with check (public.is_admin());
create policy "Admins update products" on public.products
for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "Admins delete products" on public.products
for delete to authenticated using (public.is_admin());

create policy "Customers view own orders and admins all"
on public.orders for select to authenticated
using (user_id = (select auth.uid()) or public.is_admin());
create policy "Admins update orders" on public.orders
for update to authenticated using (public.is_admin()) with check (public.is_admin());

create policy "Customers view own items and admins all"
on public.order_items for select to authenticated
using (exists(select 1 from public.orders o where o.id = order_id and (o.user_id = (select auth.uid()) or public.is_admin())));

-- The browser cannot directly insert orders/items or edit payment/status.
-- All checkout inserts run through this SECURITY DEFINER function, which checks
-- caller identity, product availability, and calculates prices on the server.
create function public.place_order(
  p_customer_name text,
  p_phone text,
  p_address text,
  p_city text,
  p_payment_method text,
  p_transaction_ref text,
  p_items jsonb
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_order uuid := gen_random_uuid();
  v_subtotal numeric(12,2) := 0;
  v_shipping numeric(12,2);
  v_total numeric(12,2);
  v_item jsonb;
  v_product public.products%rowtype;
  v_qty integer;
begin
  if v_user is null then raise exception 'Please sign in before placing an order'; end if;
  if length(trim(coalesce(p_customer_name,''))) < 2 then raise exception 'Valid customer name is required'; end if;
  if length(regexp_replace(coalesce(p_phone,''), '[^0-9]', '', 'g')) < 11 then raise exception 'Valid phone number is required'; end if;
  if length(trim(coalesce(p_address,''))) < 5 or length(trim(coalesce(p_city,''))) < 2 then raise exception 'Complete address is required'; end if;
  if p_payment_method not in ('cod','manual') then raise exception 'Invalid payment method'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) < 1 or jsonb_array_length(p_items) > 50 then raise exception 'Invalid order items'; end if;

  -- Lock each product row to avoid overselling during concurrent checkouts.
  for v_item in select value from jsonb_array_elements(p_items) loop
    if coalesce(v_item->>'product_id','') = '' then raise exception 'Invalid product'; end if;
    if coalesce(v_item->>'quantity','') !~ '^[0-9]+$' then raise exception 'Invalid quantity'; end if;
    v_qty := (v_item->>'quantity')::integer;
    if v_qty < 1 or v_qty > 100 then raise exception 'Invalid quantity'; end if;
    select * into v_product from public.products
      where id = (v_item->>'product_id')::uuid and active = true
      for update;
    if not found then raise exception 'A product is no longer available'; end if;
    if v_product.stock < v_qty then raise exception 'Insufficient stock for %', v_product.name; end if;
    v_subtotal := v_subtotal + v_product.price * v_qty;
  end loop;

  v_shipping := case when v_subtotal >= 3000 then 0 else 80 end;
  v_total := v_subtotal + v_shipping;
  insert into public.orders(id,user_id,customer_name,phone,address,city,payment_method,transaction_ref,payment_status,subtotal,shipping_fee,total)
  values(v_order,v_user,trim(p_customer_name),trim(p_phone),trim(p_address),trim(p_city),p_payment_method,nullif(trim(coalesce(p_transaction_ref,'')),''),case when p_payment_method='manual' then 'pending_verification' else 'unpaid' end,v_subtotal,v_shipping,v_total);

  for v_item in select value from jsonb_array_elements(p_items) loop
    v_qty := (v_item->>'quantity')::integer;
    select * into v_product from public.products where id = (v_item->>'product_id')::uuid for update;
    update public.products set stock = stock - v_qty, updated_at = now() where id = v_product.id;
    insert into public.order_items(order_id,product_id,product_name,unit_price,quantity)
    values(v_order,v_product.id,v_product.name,v_product.price,v_qty);
  end loop;
  return v_order;
end;
$$;
revoke all on function public.place_order(text,text,text,text,text,text,jsonb) from public;
grant execute on function public.place_order(text,text,text,text,text,text,jsonb) to authenticated;

-- Seed the initial 15 products (illustrative photos; replace with your own licensed images).
insert into public.products(name,category,price,stock,image_url,description) values
('স্মার্ট ওয়াচ','ইলেকট্রনিক্স',1890,14,'https://images.unsplash.com/photo-1523275335684-37898b6baf30?auto=format&fit=crop&w=600&q=80','স্টাইলিশ স্মার্ট ওয়াচ, দৈনন্দিন ব্যবহারের জন্য।'),
('ওয়্যারলেস ইয়ারবাড','ইলেকট্রনিক্স',1290,22,'https://images.unsplash.com/photo-1606220945770-b5b6c2c55bf1?auto=format&fit=crop&w=600&q=80','ক্লিয়ার সাউন্ড এবং আরামদায়ক ডিজাইন।'),
('প্রিমিয়াম ব্যাকপ্যাক','লাইফস্টাইল',1590,9,'https://images.unsplash.com/photo-1553062407-98eeb64c6a62?auto=format&fit=crop&w=600&q=80','টেকসই ও আধুনিক ব্যাকপ্যাক।'),
('ক্লাসিক স্নিকার্স','ফ্যাশন',2190,11,'https://images.unsplash.com/photo-1542291026-7eec264c27ff?auto=format&fit=crop&w=600&q=80','আরামদায়ক দৈনন্দিন জুতা।'),
('সানগ্লাস','অ্যাক্সেসরিজ',790,20,'https://images.unsplash.com/photo-1511499767150-a48a237f0083?auto=format&fit=crop&w=600&q=80','আধুনিক ডিজাইনের সানগ্লাস।'),
('লেদার ওয়ালেট','অ্যাক্সেসরিজ',650,18,'https://images.unsplash.com/photo-1627123424574-724758594e93?auto=format&fit=crop&w=600&q=80','স্লিম ডিজাইন, প্রতিদিনের ব্যবহারে উপযোগী।'),
('হেডফোন','ইলেকট্রনিক্স',2790,7,'https://images.unsplash.com/photo-1505740420928-5e560c06d30e?auto=format&fit=crop&w=600&q=80','প্রিমিয়াম লুক ও দারুণ সাউন্ড।'),
('স্কিনকেয়ার সেট','কসমেটিকস',990,12,'https://images.unsplash.com/photo-1608248543803-ba4f8c70ae0b?auto=format&fit=crop&w=600&q=80','দৈনন্দিন স্কিনকেয়ার রুটিনের জন্য।'),
('কিচেন স্টোরেজ সেট','হোম',850,15,'https://images.unsplash.com/photo-1495546968767-f0573cca821e?auto=format&fit=crop&w=600&q=80','রান্নাঘর গুছিয়ে রাখার সহজ সমাধান।'),
('ক্যাজুয়াল টি-শার্ট','ফ্যাশন',550,30,'https://images.unsplash.com/photo-1521572163474-6864f9cf17ab?auto=format&fit=crop&w=600&q=80','আরামদায়ক কটন টি-শার্ট।'),
('টেবিল ল্যাম্প','হোম',1250,8,'https://images.unsplash.com/photo-1507473885765-e6ed057f782c?auto=format&fit=crop&w=600&q=80','আধুনিক ডিজাইনের টেবিল ল্যাম্প।'),
('পারফিউম','কসমেটিকস',1450,10,'https://images.unsplash.com/photo-1541643600914-78b084683601?auto=format&fit=crop&w=600&q=80','দৈনন্দিন ব্যবহারের সুগন্ধি।'),
('স্পোর্টস বোতল','লাইফস্টাইল',390,25,'https://images.unsplash.com/photo-1602143407151-7111542de6e8?auto=format&fit=crop&w=600&q=80','জিম ও ভ্রমণের জন্য পানির বোতল।'),
('লেডিস হ্যান্ডব্যাগ','ফ্যাশন',1690,6,'https://images.unsplash.com/photo-1584917865442-de89df76afd3?auto=format&fit=crop&w=600&q=80','স্মার্ট ও স্টাইলিশ হ্যান্ডব্যাগ।'),
('মোবাইল চার্জার','ইলেকট্রনিক্স',690,19,'https://images.unsplash.com/photo-1583394838336-acd977736f90?auto=format&fit=crop&w=600&q=80','দৈনন্দিন ব্যবহারের চার্জিং অ্যাক্সেসরি।');
