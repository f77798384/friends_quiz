-- Friends Quiz v4 upgrade (run AFTER upgrade_v3.sql).
-- Only the host can remove another player, and only while the room is in draft.
-- Existing quiz_players -> quiz_questions/submissions foreign keys cascade on deletion.
create or replace function public.kick_player(
  p_room_id uuid, p_player_id uuid, p_target_player_id uuid
) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v_host public.quiz_players; v_target public.quiz_players; v_status public.quiz_room_status;
begin
  v_host := public._assert_member(p_room_id,p_player_id);
  if not v_host.is_host then raise exception '僅主持人可剔除參加者'; end if;
  select status into v_status from public.quiz_rooms where id=p_room_id for update;
  if v_status is distinct from 'draft' then raise exception '題庫鎖定後不能剔除參加者'; end if;
  if p_target_player_id=p_player_id then raise exception '主持人不能剔除自己'; end if;
  select * into v_target from public.quiz_players where room_id=p_room_id and id=p_target_player_id for update;
  if not found then raise exception '找不到參加者'; end if;
  if v_target.is_host then raise exception '不能剔除主持人'; end if;
  delete from public.quiz_players where id=p_target_player_id and room_id=p_room_id;
  return jsonb_build_object('removed',true,'nickname',v_target.nickname);
end $$;
revoke all on function public.kick_player(uuid,uuid,uuid) from public;
grant execute on function public.kick_player(uuid,uuid,uuid) to anon,authenticated;
