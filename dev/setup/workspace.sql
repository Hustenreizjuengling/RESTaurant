--------------------------------------------------------------------------------
-- Creates the schemas, the APEX workspace and a developer account that are
-- used to develop and test RESTaurant. Run as SYS on the pluggable database.
--------------------------------------------------------------------------------
whenever sqlerror exit failure
set define off

declare
  procedure create_schema (p_name in varchar2) is
    l_cnt pls_integer;
  begin
    select count(*) into l_cnt from dba_users where username = p_name;
    if l_cnt = 0 then
      execute immediate 'create user ' || p_name || ' identified by "Restaurant_4U" default tablespace users quota unlimited on users';
      execute immediate 'grant create session, create table, create view, create sequence, create procedure, create type, create trigger, create synonym to ' || p_name;
    end if;
  end create_schema;
begin
  create_schema('RESTAURANT');
  create_schema('RESTAURANT_B');
end;
/

declare
  l_cnt pls_integer;
begin
  select count(*) into l_cnt from apex_workspaces where workspace = 'RESTAURANT';
  if l_cnt = 0 then
    apex_instance_admin.add_workspace(
      p_workspace          => 'RESTAURANT',
      p_primary_schema     => 'RESTAURANT',
      p_additional_schemas => 'RESTAURANT_B');
  end if;
  commit;
end;
/

declare
  l_cnt pls_integer;
begin
  apex_util.set_workspace('RESTAURANT');
  select count(*) into l_cnt
    from apex_workspace_apex_users
   where workspace_name = 'RESTAURANT' and user_name = 'DEV';
  if l_cnt = 0 then
    apex_util.create_user(
      p_user_name                    => 'DEV',
      p_email_address                => 'dev@example.com',
      p_web_password                 => 'Restaurant_4U',
      p_developer_privs              => 'ADMIN:CREATE:DATA_LOADER:EDIT:HELP:MONITOR:SQL',
      p_default_schema               => 'RESTAURANT',
      p_change_password_on_first_use => 'N');
  end if;
  commit;
end;
/

select workspace, workspace_id from apex_workspaces where workspace = 'RESTAURANT';
exit
