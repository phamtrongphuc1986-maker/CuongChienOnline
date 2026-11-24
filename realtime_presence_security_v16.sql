-- Applied to Supabase project CuongChienOnline.
drop policy if exists game_village_authenticated_write on realtime.messages;
create policy game_village_authenticated_presence_write
on realtime.messages
for insert
to authenticated
with check (
 (select realtime.topic()) = 'game-village'
 and extension = 'presence'
);

-- Authenticated game clients may publish Presence tracking only.
-- Broadcast events player_position and monster_position are emitted by
-- database triggers using realtime.send(..., true), not trusted from clients.
