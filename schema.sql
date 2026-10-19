-- Twassol schema: شغّل هذا الملف كاملًا في Supabase > SQL Editor > New query.
create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text unique not null check (username ~ '^[a-z0-9_]{3,24}$'),
  display_name text not null default 'مستخدم' check (char_length(display_name) <= 50),
  bio text not null default '' check (char_length(bio) <= 250),
  avatar_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table if not exists public.posts (
  id uuid primary key default gen_random_uuid(),
  author_id uuid not null references public.profiles(id) on delete cascade,
  content text not null default '' check (char_length(content) <= 3000),
  image_url text,
  created_at timestamptz not null default now(),
  check (char_length(content) > 0 or image_url is not null)
);
create table if not exists public.comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.posts(id) on delete cascade,
  author_id uuid not null references public.profiles(id) on delete cascade,
  content text not null check (char_length(content) between 1 and 1000),
  created_at timestamptz not null default now()
);
create table if not exists public.likes (
  post_id uuid not null references public.posts(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key(post_id,user_id)
);
create table if not exists public.follows (
  follower_id uuid not null references public.profiles(id) on delete cascade,
  following_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key(follower_id,following_id),
  check(follower_id <> following_id)
);
create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  actor_id uuid references public.profiles(id) on delete set null,
  type text not null check(type in ('like','comment','follow')),
  post_id uuid references public.posts(id) on delete cascade,
  is_read boolean not null default false,
  created_at timestamptz not null default now()
);

create index if not exists posts_created_idx on public.posts(created_at desc);
create index if not exists posts_author_idx on public.posts(author_id,created_at desc);
create index if not exists comments_post_idx on public.comments(post_id,created_at);
create index if not exists notifications_recipient_idx on public.notifications(recipient_id,created_at desc);

alter table public.profiles enable row level security;
alter table public.posts enable row level security;
alter table public.comments enable row level security;
alter table public.likes enable row level security;
alter table public.follows enable row level security;
alter table public.notifications enable row level security;

drop policy if exists "profiles readable" on public.profiles;
create policy "profiles readable" on public.profiles for select to authenticated using (true);
drop policy if exists "user inserts own profile" on public.profiles;
create policy "user inserts own profile" on public.profiles for insert to authenticated with check (auth.uid()=id);
drop policy if exists "user updates own profile" on public.profiles;
create policy "user updates own profile" on public.profiles for update to authenticated using (auth.uid()=id) with check (auth.uid()=id);

drop policy if exists "posts readable" on public.posts;
create policy "posts readable" on public.posts for select to authenticated using (true);
drop policy if exists "users create own posts" on public.posts;
create policy "users create own posts" on public.posts for insert to authenticated with check (auth.uid()=author_id);
drop policy if exists "authors delete posts" on public.posts;
create policy "authors delete posts" on public.posts for delete to authenticated using (auth.uid()=author_id);

drop policy if exists "comments readable" on public.comments;
create policy "comments readable" on public.comments for select to authenticated using (true);
drop policy if exists "users create own comments" on public.comments;
create policy "users create own comments" on public.comments for insert to authenticated with check (auth.uid()=author_id);
drop policy if exists "authors delete own comments" on public.comments;
create policy "authors delete own comments" on public.comments for delete to authenticated using (auth.uid()=author_id);

drop policy if exists "likes readable" on public.likes;
create policy "likes readable" on public.likes for select to authenticated using (true);
drop policy if exists "users like as themselves" on public.likes;
create policy "users like as themselves" on public.likes for insert to authenticated with check (auth.uid()=user_id);
drop policy if exists "users remove own likes" on public.likes;
create policy "users remove own likes" on public.likes for delete to authenticated using (auth.uid()=user_id);

drop policy if exists "follows readable" on public.follows;
create policy "follows readable" on public.follows for select to authenticated using (true);
drop policy if exists "users follow as themselves" on public.follows;
create policy "users follow as themselves" on public.follows for insert to authenticated with check (auth.uid()=follower_id);
drop policy if exists "users unfollow as themselves" on public.follows;
create policy "users unfollow as themselves" on public.follows for delete to authenticated using (auth.uid()=follower_id);

drop policy if exists "users read own notifications" on public.notifications;
create policy "users read own notifications" on public.notifications for select to authenticated using (auth.uid()=recipient_id);
drop policy if exists "users mark own notifications" on public.notifications;
create policy "users mark own notifications" on public.notifications for update to authenticated using (auth.uid()=recipient_id) with check (auth.uid()=recipient_id);

-- Automatically create a basic profile after sign-up.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public
as $$
declare base_name text;
begin
  base_name := lower(regexp_replace(split_part(coalesce(new.email,'user'), '@', 1), '[^a-zA-Z0-9_]', '', 'g'));
  if length(base_name) < 3 then base_name := 'user'; end if;
  insert into public.profiles(id,username,display_name)
  values(new.id, left(base_name,16) || '_' || substr(new.id::text,1,5), left(base_name,50))
  on conflict (id) do nothing;
  return new;
end;
$$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute procedure public.handle_new_user();

-- Create notification rows for likes, comments and follows. The target recipient is looked up server-side.
create or replace function public.notify_like()
returns trigger language plpgsql security definer set search_path = public
as $$ declare owner_id uuid; begin
 select author_id into owner_id from public.posts where id=new.post_id;
 if owner_id is not null and owner_id <> new.user_id then
   insert into public.notifications(recipient_id,actor_id,type,post_id) values(owner_id,new.user_id,'like',new.post_id);
 end if; return new; end; $$;
drop trigger if exists like_notification on public.likes;
create trigger like_notification after insert on public.likes for each row execute procedure public.notify_like();

create or replace function public.notify_comment()
returns trigger language plpgsql security definer set search_path = public
as $$ declare owner_id uuid; begin
 select author_id into owner_id from public.posts where id=new.post_id;
 if owner_id is not null and owner_id <> new.author_id then
   insert into public.notifications(recipient_id,actor_id,type,post_id) values(owner_id,new.author_id,'comment',new.post_id);
 end if; return new; end; $$;
drop trigger if exists comment_notification on public.comments;
create trigger comment_notification after insert on public.comments for each row execute procedure public.notify_comment();

create or replace function public.notify_follow()
returns trigger language plpgsql security definer set search_path = public
as $$ begin
 insert into public.notifications(recipient_id,actor_id,type) values(new.following_id,new.follower_id,'follow');
 return new; end; $$;
drop trigger if exists follow_notification on public.follows;
create trigger follow_notification after insert on public.follows for each row execute procedure public.notify_follow();

-- Public image bucket. Use only for non-sensitive images.
insert into storage.buckets (id,name,public,file_size_limit,allowed_mime_types)
values ('twassol-images','twassol-images',true,5242880,array['image/jpeg','image/png','image/webp','image/gif'])
on conflict (id) do update set public=true,file_size_limit=5242880,allowed_mime_types=array['image/jpeg','image/png','image/webp','image/gif'];

drop policy if exists "authenticated can view Twassol images" on storage.objects;
create policy "authenticated can view Twassol images" on storage.objects for select to authenticated using (bucket_id='twassol-images');
drop policy if exists "users upload to own folder" on storage.objects;
create policy "users upload to own folder" on storage.objects for insert to authenticated with check (bucket_id='twassol-images' and (storage.foldername(name))[1]=auth.uid()::text);
drop policy if exists "users delete own images" on storage.objects;
create policy "users delete own images" on storage.objects for delete to authenticated using (bucket_id='twassol-images' and (storage.foldername(name))[1]=auth.uid()::text);
