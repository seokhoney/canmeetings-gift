-- 먼저 이 파일에서 REPLACE_ADMIN_USER_UUID 를 실제 Authentication > Users UID로 교체하세요.
create extension if not exists pgcrypto with schema extensions;

create table if not exists public.gift_awards (
 id text primary key, name text not null, limit_amount integer not null check (limit_amount > 0)
);
insert into public.gift_awards(id,name,limit_amount) values
 ('project','프로젝트 소개 1등팀',44000),('overall','종합 1등팀',33000),
 ('quiz','초성·음악퀴즈 개인 1등',22000),('photo','포토제닉상',22000),
 ('team','줄줄이 말해요·고깔게임 우승팀',16500),('lucky','럭키드로우',11000)
on conflict (id) do update set name=excluded.name,limit_amount=excluded.limit_amount;

create table if not exists public.gift_products (
 id text primary key, price integer not null check (price >= 8000), active boolean not null default true
);

create table if not exists public.gift_pins (
 id uuid primary key default gen_random_uuid(),
 award_id text not null references public.gift_awards(id),
 pin_hash text not null,
 recipient_name text,
 created_at timestamptz not null default now(),
 expires_at timestamptz not null default (now()+interval '30 days'),
 used_at timestamptz,
 revoked_at timestamptz
);
create index if not exists gift_pins_unused_idx on public.gift_pins(award_id) where used_at is null and revoked_at is null;

-- 기존 operator_id 는 직접 로그인한 운영자 ID였으나 PIN 참가자는 로그인하지 않습니다.
-- 익명 PIN 확정분은 operator_id=NULL로 기록하고 pin_id로 식별합니다.
alter table public.gift_selections alter column operator_id drop not null;
alter table public.gift_selections add column if not exists pin_id uuid references public.gift_pins(id);
create unique index if not exists gift_selections_pin_id_uniq on public.gift_selections(pin_id) where pin_id is not null;

-- 웹 클라이언트는 PIN 원문 및 서버 가격 테이블을 직접 조회하지 못함.
revoke all on public.gift_pins,public.gift_awards,public.gift_products from anon,authenticated;
alter table public.gift_pins enable row level security;
alter table public.gift_awards enable row level security;
alter table public.gift_products enable row level security;

-- 관리자는 로그인 후 PIN 목록 확인, 발급/폐기 함수 호출만 가능.
grant select on public.gift_pins to authenticated;
drop policy if exists "Gift PIN admin read" on public.gift_pins;
create policy "Gift PIN admin read" on public.gift_pins for select to authenticated
 using (auth.uid() = 'REPLACE_ADMIN_USER_UUID'::uuid);

create or replace function public.admin_issue_gift_pin(p_award_id text,p_pin text,p_recipient_name text default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
 if auth.uid() is distinct from 'REPLACE_ADMIN_USER_UUID'::uuid then raise exception 'not authorized'; end if;
 if p_pin !~ '^[A-HJ-NP-Z2-9]{12}$' then raise exception 'invalid PIN format'; end if;
 if not exists(select 1 from public.gift_awards where id=p_award_id) then raise exception 'invalid award'; end if;
 insert into public.gift_pins(award_id,pin_hash,recipient_name)
 values(p_award_id,extensions.crypt(p_pin,extensions.gen_salt('bf')),nullif(trim(p_recipient_name),'')) returning id into v_id;
 return v_id;
end $$;
create or replace function public.admin_revoke_gift_pin(p_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
 if auth.uid() is distinct from 'REPLACE_ADMIN_USER_UUID'::uuid then raise exception 'not authorized'; end if;
 update public.gift_pins set revoked_at=now() where id=p_id and used_at is null and revoked_at is null;
end $$;
revoke all on function public.admin_issue_gift_pin(text,text,text) from public,anon;
revoke all on function public.admin_revoke_gift_pin(uuid) from public,anon;
grant execute on function public.admin_issue_gift_pin(text,text,text) to authenticated;
grant execute on function public.admin_revoke_gift_pin(uuid) to authenticated;

-- Edge Function(service_role 전용)에서 호출하는 함수. 일반 방문자에게는 EXECUTE 불허.
create or replace function public.verify_gift_pin_server(p_pin text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_row record;
begin
 if auth.role() <> 'service_role' then raise exception 'forbidden'; end if;
 select a.id,a.name,a.limit_amount into v_row
 from public.gift_pins p join public.gift_awards a on a.id=p.award_id
 where p.used_at is null and p.revoked_at is null and p.expires_at>now()
 and p.pin_hash=extensions.crypt(p_pin,p.pin_hash) limit 1;
 if not found then return jsonb_build_object('ok',false,'message','유효하지 않거나 이미 사용된 PIN입니다.'); end if;
 return jsonb_build_object('ok',true,'award',jsonb_build_object('id',v_row.id,'name',v_row.name,'limit',v_row.limit_amount));
end $$;

create or replace function public.confirm_gift_pin_server(p_pin text,p_request_id uuid,p_winner_name text,p_items jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_pin record; v_item jsonb;v_id text;v_qty int;v_price int;v_items jsonb='[]'::jsonb;v_total bigint=0;v_selection uuid;v_existing record;
begin
 if auth.role()<>'service_role' then raise exception 'forbidden'; end if;
 if length(trim(coalesce(p_winner_name,''))) not between 1 and 60 then raise exception 'invalid winner name'; end if;
 if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)<1 or jsonb_array_length(p_items)>30 then raise exception 'invalid items'; end if;
 -- 같은 PIN에 대한 중복 확정/경합 요청을 행 잠금으로 직렬화.
 select p.id,a.id award_id,a.name award_name,a.limit_amount,p.used_at
 into v_pin from public.gift_pins p join public.gift_awards a on a.id=p.award_id
 where p.pin_hash=extensions.crypt(p_pin,p.pin_hash) for update of p;
 if not found then raise exception 'invalid PIN'; end if;
 if v_pin.used_at is not null then
   select id,request_id,winner_name into v_existing from public.gift_selections where pin_id=v_pin.id;
   if v_existing.request_id=p_request_id then
     return jsonb_build_object('ok',true,'selection',jsonb_build_object('id',v_existing.id,'winner_name',v_existing.winner_name,'award_id',v_pin.award_id,'award_name',v_pin.award_name),'already_saved',true);
   end if;
   raise exception 'PIN already used';
 end if;
 if exists(select 1 from public.gift_pins p where p.id=v_pin.id and (p.revoked_at is not null or p.expires_at<=now())) then raise exception 'PIN revoked or expired'; end if;
 for v_item in select * from jsonb_array_elements(p_items) loop
   v_id=v_item->>'goodsNo';
   if v_id is null or coalesce(v_item->>'quantity','') !~ '^[0-9]{1,3}$' then raise exception 'invalid item'; end if;
   v_qty=(v_item->>'quantity')::integer;
   if v_qty<1 or v_qty>30 then raise exception 'invalid quantity'; end if;
   select price into v_price from public.gift_products where id=v_id and active=true;
   if not found then raise exception 'unknown item %',v_id;end if;
   if exists(select 1 from jsonb_array_elements(v_items) x where x->>'goodsNo'=v_id) then raise exception 'duplicate item';end if;
   v_total=v_total+(v_price::bigint*v_qty);
   if v_total>v_pin.limit_amount then raise exception 'award budget exceeded';end if;
   v_items=v_items||jsonb_build_array(jsonb_build_object('goodsNo',v_id,'quantity',v_qty,'unitDiscountPrice',v_price));
 end loop;
 insert into public.gift_selections(request_id,winner_name,award_id,award_name,items,total_price,pin_id)
 values(p_request_id,trim(p_winner_name),v_pin.award_id,v_pin.award_name,v_items,v_total,v_pin.id)
 returning id into v_selection;
 update public.gift_pins set used_at=now() where id=v_pin.id;
 return jsonb_build_object('ok',true,'selection',jsonb_build_object('id',v_selection,'winner_name',trim(p_winner_name),'award_id',v_pin.award_id,'award_name',v_pin.award_name,'total_price',v_total));
end $$;
revoke all on function public.verify_gift_pin_server(text) from public,anon,authenticated;
revoke all on function public.confirm_gift_pin_server(text,uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.verify_gift_pin_server(text) to service_role;
grant execute on function public.confirm_gift_pin_server(text,uuid,text,jsonb) to service_role;
