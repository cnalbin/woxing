begin;

create table if not exists public.woxing_snapshots (
    user_id uuid primary key references auth.users(id) on delete cascade,
    revision bigint not null default 1 check (revision >= 1),
    payload jsonb not null check (
        coalesce(jsonb_typeof(payload -> 'items') = 'array', false)
        and coalesce(jsonb_typeof(payload -> 'lists') = 'array', false)
        and octet_length(payload::text) <= 5242880
    )
);

alter table public.woxing_snapshots enable row level security;
revoke all on table public.woxing_snapshots from public, anon, authenticated;
grant select, insert, update on table public.woxing_snapshots to authenticated;

drop policy if exists woxing_own_snapshot on public.woxing_snapshots;
create policy woxing_own_snapshot on public.woxing_snapshots
    for all to authenticated
    using ((select auth.uid()) = user_id)
    with check ((select auth.uid()) = user_id);

create or replace function public.woxing_save_snapshot(expected_revision bigint, new_payload jsonb)
returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
declare
    owner_id uuid := auth.uid();
begin
    if owner_id is null then
        raise insufficient_privilege;
    end if;

    if expected_revision = 0 then
        insert into public.woxing_snapshots (user_id, revision, payload)
        values (owner_id, 1, new_payload)
        on conflict (user_id) do nothing;
    else
        update public.woxing_snapshots
        set revision = revision + 1, payload = new_payload
        where user_id = owner_id and revision = expected_revision;
    end if;

    return found;
end;
$$;

revoke all on function public.woxing_save_snapshot(bigint, jsonb) from public, anon, authenticated;
grant execute on function public.woxing_save_snapshot(bigint, jsonb) to authenticated;

commit;
