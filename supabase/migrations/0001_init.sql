-- arkyv initial schema: folders, items, devices.
-- Row Level Security is enabled on every table and scoped to the
-- authenticated user (auth.uid() = user_id). Notes are modeled as items with
-- type 'note' | 'text' carrying note_body, per the app's data model.

-- ─────────────────────────────── folders ───────────────────────────────
create table if not exists public.folders (
    id          uuid primary key default gen_random_uuid(),
    user_id     uuid not null references auth.users (id) on delete cascade,
    name        text not null,
    icon        text not null default 'sf:folder',
    sort_order  int  not null default 0,
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now()
);

-- ──────────────────────────────── items ────────────────────────────────
create type public.item_type as enum ('screenshot', 'image', 'note', 'text');

create table if not exists public.items (
    id            uuid primary key default gen_random_uuid(),
    user_id       uuid not null references auth.users (id) on delete cascade,
    folder_id     uuid references public.folders (id) on delete cascade,
    type          public.item_type not null,
    storage_path  text,
    ocr_text      text,
    note_body     text,
    title         text,
    source_url    text,
    tags          text[] not null default '{}',
    is_favorite   boolean not null default false,
    aspect_width  double precision not null default 0,
    aspect_height double precision not null default 0,
    source_device text not null default 'unknown',
    created_at    timestamptz not null default now(),
    updated_at    timestamptz not null default now()
);

-- Full-text search over the item's textual content (OCR, note, title, source).
alter table public.items
    add column if not exists fts tsvector
    generated always as (
        to_tsvector('english',
            coalesce(ocr_text, '') || ' ' ||
            coalesce(note_body, '') || ' ' ||
            coalesce(title, '') || ' ' ||
            coalesce(source_url, '') || ' ' ||
            array_to_string(tags, ' ')
        )
    ) stored;

create index if not exists items_fts_idx        on public.items using gin (fts);
create index if not exists items_folder_id_idx  on public.items (folder_id);
create index if not exists items_user_id_idx    on public.items (user_id);
create index if not exists folders_user_id_idx  on public.folders (user_id);

-- ─────────────────────────────── devices ───────────────────────────────
create table if not exists public.devices (
    id          uuid primary key default gen_random_uuid(),
    user_id     uuid not null references auth.users (id) on delete cascade,
    name        text not null,
    platform    text not null,
    last_seen   timestamptz not null default now()
);

-- ─────────────────────────── updated_at trigger ────────────────────────
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin
    new.updated_at = now();
    return new;
end;
$$;

create trigger folders_touch before update on public.folders
    for each row execute function public.touch_updated_at();
create trigger items_touch before update on public.items
    for each row execute function public.touch_updated_at();

-- ───────────────────────────────── RLS ─────────────────────────────────
alter table public.folders enable row level security;
alter table public.items   enable row level security;
alter table public.devices enable row level security;

create policy "folders are private to owner" on public.folders
    for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "items are private to owner" on public.items
    for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "devices are private to owner" on public.devices
    for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- ───────────────────────── realtime + storage ──────────────────────────
-- Broadcast row changes to per-user Realtime subscriptions (shared clipboard).
alter publication supabase_realtime add table public.items;
alter publication supabase_realtime add table public.folders;

-- Private Storage bucket for capture images.
insert into storage.buckets (id, name, public)
values ('captures', 'captures', false)
on conflict (id) do nothing;

-- Storage objects are namespaced by user id as the first path segment:
--   captures/<user_id>/<item_id>.jpg
create policy "own captures readable" on storage.objects
    for select using (
        bucket_id = 'captures' and (storage.foldername(name))[1] = auth.uid()::text
    );
create policy "own captures writable" on storage.objects
    for insert with check (
        bucket_id = 'captures' and (storage.foldername(name))[1] = auth.uid()::text
    );
create policy "own captures deletable" on storage.objects
    for delete using (
        bucket_id = 'captures' and (storage.foldername(name))[1] = auth.uid()::text
    );
