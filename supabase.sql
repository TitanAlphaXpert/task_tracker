-- JOB CARD TRACKER — SUPABASE SETUP
-- Run this entire script once in Supabase SQL Editor.
-- Then create employees/dealership data through the app's manager screen.
-- IMPORTANT: Change the manager PIN below before using the system.

create extension if not exists pgcrypto;

create table if not exists public.dealerships(
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.people(
  id uuid primary key default gen_random_uuid(),
  dealer_id uuid not null references public.dealerships(id),
  name text not null,
  pin_hash text not null,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.tasks(
  id uuid primary key default gen_random_uuid(),
  dealer_id uuid not null references public.dealerships(id),
  assigned_to uuid not null references public.people(id),
  title text not null,
  due_date date not null,
  status text not null default 'pending' check(status in ('pending','help','done','late')),
  help_note text,
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  updated_at timestamptz not null default now()
);

create table if not exists public.audit_log(
  id bigint generated always as identity primary key,
  dealer_id uuid references public.dealerships(id),
  person_id uuid references public.people(id),
  task_id uuid references public.tasks(id),
  action text not null,
  details jsonb,
  created_at timestamptz not null default now()
);

-- Seed the three dealerships. Rename these if your actual dealership names differ.
insert into public.dealerships(name) values
('ATC Mobility Aurangabad'),
('Unicon Latur'),
('Unicon Ahmednagar')
on conflict(name) do nothing;

-- RLS: browser should not directly read/write these tables.
alter table public.dealerships enable row level security;
alter table public.people enable row level security;
alter table public.tasks enable row level security;
alter table public.audit_log enable row level security;

revoke all on public.dealerships from anon, authenticated;
revoke all on public.people from anon, authenticated;
revoke all on public.tasks from anon, authenticated;
revoke all on public.audit_log from anon, authenticated;

-- Public dealership list only exposes active dealership id/name.
create or replace function public.public_get_dealers()
returns table(id uuid,name text)
language sql
security definer
set search_path=public
as $$ select d.id,d.name from public.dealerships d where d.active order by d.name $$;
grant execute on function public.public_get_dealers() to anon, authenticated;

create or replace function public.public_get_people(p_dealer_id uuid)
returns table(id uuid,name text)
language sql
security definer
set search_path=public
as $$ select p.id,p.name from public.people p where p.dealer_id=p_dealer_id and p.active order by p.name $$;
grant execute on function public.public_get_people(uuid) to anon, authenticated;

-- Replace this value with your chosen manager PIN hash.
-- To generate a hash, run:
-- select encode(digest('YOUR_MANAGER_PIN','sha256'),'hex');
create table if not exists public.app_config(
  key text primary key,
  value text not null
);
alter table public.app_config enable row level security;
revoke all on public.app_config from anon, authenticated;
insert into public.app_config(key,value)
values('manager_pin_hash',encode(digest('CHANGE-ME-1234','sha256'),'hex'))
on conflict(key) do nothing;

create or replace function public.manager_verify(p_pin text)
returns boolean
language plpgsql
security definer
set search_path=public
as $$
declare ok boolean;
begin
  select encode(digest(p_pin,'sha256'),'hex')=value into ok from public.app_config where key='manager_pin_hash';
  return coalesce(ok,false);
end $$;
grant execute on function public.manager_verify(text) to anon, authenticated;

create or replace function public.employee_verify(p_person_id uuid,p_pin text)
returns boolean
language plpgsql
security definer
set search_path=public
as $$
declare ok boolean;
begin
  select encode(digest(p_pin,'sha256'),'hex')=pin_hash into ok from public.people where id=p_person_id and active;
  return coalesce(ok,false);
end $$;
grant execute on function public.employee_verify(uuid,text) to anon, authenticated;

create or replace function public.employee_get_tasks(p_person_id uuid,p_pin text)
returns json
language plpgsql
security definer
set search_path=public
as $$
declare result json;
begin
  if not public.employee_verify(p_person_id,p_pin) then raise exception 'Invalid employee credentials'; end if;
  select json_build_object(
    'person',json_build_object('id',p.id,'name',p.name,'dealer_name',d.name),
    'tasks',coalesce((select json_agg(t order by t.due_date asc,t.created_at asc) from public.tasks t where t.assigned_to=p.id),'[]'::json)
  ) into result
  from public.people p join public.dealerships d on d.id=p.dealer_id
  where p.id=p_person_id;
  return result;
end $$;
grant execute on function public.employee_get_tasks(uuid,text) to anon, authenticated;

create or replace function public.employee_complete_task(p_task_id uuid,p_person_id uuid,p_pin text)
returns boolean
language plpgsql
security definer
set search_path=public
as $$
declare due date; dealer uuid; newstatus text;
begin
  if not public.employee_verify(p_person_id,p_pin) then raise exception 'Invalid employee credentials'; end if;
  select due_date,dealer_id into due,dealer from public.tasks where id=p_task_id and assigned_to=p_person_id;
  if due is null then raise exception 'Task not found'; end if;
  newstatus:=case when (now() at time zone 'Asia/Kolkata')::date > due then 'late' else 'done' end;
  update public.tasks set status=newstatus,completed_at=now(),help_note=null,updated_at=now() where id=p_task_id and assigned_to=p_person_id;
  insert into public.audit_log(dealer_id,person_id,task_id,action,details) values(dealer,p_person_id,p_task_id,'completed',json_build_object('status',newstatus));
  return true;
end $$;
grant execute on function public.employee_complete_task(uuid,uuid,text) to anon, authenticated;

create or replace function public.employee_help_task(p_task_id uuid,p_person_id uuid,p_pin text,p_note text)
returns boolean
language plpgsql
security definer
set search_path=public
as $$
declare dealer uuid;
begin
  if not public.employee_verify(p_person_id,p_pin) then raise exception 'Invalid employee credentials'; end if;
  select dealer_id into dealer from public.tasks where id=p_task_id and assigned_to=p_person_id;
  if dealer is null then raise exception 'Task not found'; end if;
  update public.tasks set status='help',help_note=left(trim(p_note),1000),updated_at=now() where id=p_task_id and assigned_to=p_person_id;
  insert into public.audit_log(dealer_id,person_id,task_id,action,details) values(dealer,p_person_id,p_task_id,'help_requested',json_build_object('note',left(trim(p_note),1000)));
  return true;
end $$;
grant execute on function public.employee_help_task(uuid,uuid,text,text) to anon, authenticated;

create or replace function public.manager_get_data(p_pin text)
returns json
language plpgsql
security definer
set search_path=public
as $$
begin
  if not public.manager_verify(p_pin) then raise exception 'Invalid manager credentials'; end if;
  return json_build_object(
    'dealers',coalesce((select json_agg(d order by d.name) from public.dealerships d where d.active),'[]'::json),
    'people',coalesce((select json_agg(json_build_object('id',p.id,'dealer_id',p.dealer_id,'name',p.name,'active',p.active)) from public.people p where p.active),'[]'::json),
    'tasks',coalesce((select json_agg(t order by t.due_date desc,t.created_at desc) from public.tasks t),'[]'::json)
  );
end $$;
grant execute on function public.manager_get_data(text) to anon, authenticated;

create or replace function public.manager_add_person(p_manager_pin text,p_dealer_id uuid,p_name text,p_employee_pin text)
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare new_id uuid;
begin
  if not public.manager_verify(p_manager_pin) then raise exception 'Invalid manager credentials'; end if;
  if not exists(select 1 from public.dealerships where id=p_dealer_id and active) then raise exception 'Invalid dealership'; end if;
  if trim(p_name)='' or p_employee_pin !~ '^\\d{4,6}$' then raise exception 'Invalid employee details'; end if;
  insert into public.people(dealer_id,name,pin_hash)
  values(p_dealer_id,trim(p_name),encode(digest(p_employee_pin,'sha256'),'hex'))
  returning id into new_id;
  return new_id;
end $$;
grant execute on function public.manager_add_person(text,uuid,text,text) to anon, authenticated;


create or replace function public.manager_create_task(p_pin text,p_dealer_id uuid,p_assigned_to uuid,p_title text,p_due_date date)
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare new_id uuid;
begin
  if not public.manager_verify(p_pin) then raise exception 'Invalid manager credentials'; end if;
  if not exists(select 1 from public.people where id=p_assigned_to and dealer_id=p_dealer_id and active) then raise exception 'Employee/dealership mismatch'; end if;
  insert into public.tasks(dealer_id,assigned_to,title,due_date)
  values(p_dealer_id,p_assigned_to,trim(p_title),p_due_date)
  returning id into new_id;
  insert into public.audit_log(dealer_id,task_id,action,details)
  values(p_dealer_id,new_id,'created',json_build_object('assigned_to',p_assigned_to));
  return new_id;
end $$;
grant execute on function public.manager_create_task(text,uuid,uuid,text,date) to anon, authenticated;

create or replace function public.manager_delete_task(p_pin text,p_task_id uuid)
returns boolean
language plpgsql
security definer
set search_path=public
as $$
declare dealer uuid;
begin
  if not public.manager_verify(p_pin) then raise exception 'Invalid manager credentials'; end if;
  select dealer_id into dealer from public.tasks where id=p_task_id;
  if dealer is null then raise exception 'Task not found'; end if;
  delete from public.tasks where id=p_task_id;
  insert into public.audit_log(dealer_id,task_id,action) values(dealer,p_task_id,'deleted');
  return true;
end $$;
grant execute on function public.manager_delete_task(text,uuid) to anon, authenticated;

create or replace function public.manager_remove_person(p_pin text,p_person_id uuid)
returns boolean
language plpgsql
security definer
set search_path=public
as $$
begin
  if not public.manager_verify(p_pin) then raise exception 'Invalid manager credentials'; end if;
  update public.people set active=false where id=p_person_id;
  return true;
end $$;
grant execute on function public.manager_remove_person(text,uuid) to anon, authenticated;

-- Optional task reassignment is supported by manager_update_task.
drop function if exists public.manager_update_task(text,uuid,text,date);
create or replace function public.manager_update_task(
  p_pin text,p_task_id uuid,p_title text,p_due_date date,p_assigned_to uuid
)
returns boolean
language plpgsql
security definer
set search_path=public
as $$
declare dealer uuid; newdealer uuid;
begin
  if not public.manager_verify(p_pin) then raise exception 'Invalid manager credentials'; end if;
  select dealer_id into dealer from public.tasks where id=p_task_id;
  if dealer is null then raise exception 'Task not found'; end if;
  select dealer_id into newdealer from public.people where id=p_assigned_to and active;
  if newdealer is null then raise exception 'Invalid employee'; end if;
  update public.tasks
  set title=trim(p_title),due_date=p_due_date,assigned_to=p_assigned_to,dealer_id=newdealer,updated_at=now()
  where id=p_task_id;
  insert into public.audit_log(dealer_id,task_id,action,details)
  values(newdealer,p_task_id,'updated',json_build_object('title',trim(p_title),'due_date',p_due_date,'assigned_to',p_assigned_to));
  return true;
end $$;
grant execute on function public.manager_update_task(text,uuid,text,date,uuid) to anon, authenticated;


create or replace function public.manager_set_task_status(p_pin text,p_task_id uuid,p_status text)
returns boolean
language plpgsql
security definer
set search_path=public
as $$
declare dealer uuid;
begin
  if not public.manager_verify(p_pin) then raise exception 'Invalid manager credentials'; end if;
  if p_status not in ('pending','help') then raise exception 'Invalid status'; end if;
  select dealer_id into dealer from public.tasks where id=p_task_id;
  if dealer is null then raise exception 'Task not found'; end if;
  update public.tasks
  set status=p_status,
      help_note=case when p_status='pending' then null else help_note end,
      completed_at=case when p_status='pending' then null else completed_at end,
      updated_at=now()
  where id=p_task_id;
  insert into public.audit_log(dealer_id,task_id,action,details)
  values(dealer,p_task_id,'status_changed',json_build_object('status',p_status));
  return true;
end $$;
grant execute on function public.manager_set_task_status(text,uuid,text) to anon, authenticated;
