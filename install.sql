--------------------------------------------------------------------------------
-- Installs RESTaurant with SQLcl or SQL*Plus.
--
--   sql user/password@database @install.sql <workspace> <schema> [application id]
--
--   workspace       APEX workspace the application is installed into
--   schema          parsing schema, the application edits the RESTful services
--                   of this schema; it has to be assigned to the workspace
--   application id  optional, a free id is generated when it is omitted
--
-- Connect as the parsing schema or as a user with APEX_ADMINISTRATOR_ROLE and
-- start the script from the root directory of the repository. To manage several
-- schemas, install the application once per schema.
--------------------------------------------------------------------------------
set define on verify off feedback off serveroutput on
whenever sqlerror exit failure rollback

-- make the third argument optional
column 3 new_value 3 noprint
select null "3" from dual where 1 = 2;

declare
    l_workspace varchar2(255) := upper('&1');
    l_schema    varchar2(128) := upper('&2');
    l_app_id    number        := to_number('&3');
    l_alias     varchar2(255) := 'RESTAURANT';
    l_count     number;
begin
    apex_application_install.set_workspace(l_workspace);
    apex_application_install.set_schema(l_schema);
    apex_application_install.generate_offset;
    if l_app_id is null then
        apex_application_install.generate_application_id;
    else
        apex_application_install.set_application_id(l_app_id);
    end if;
    -- the alias has to be unique within the workspace
    select count(*)
      into l_count
      from apex_applications
     where workspace = l_workspace
       and alias = l_alias
       and application_id <> nvl(l_app_id, -1);
    if l_count > 0 then
        l_alias := l_alias || '-' || l_schema;
    end if;
    apex_application_install.set_application_alias(l_alias);
    dbms_output.put_line('Installing RESTaurant as application ' || apex_application_install.get_application_id
        || ' (alias ' || l_alias || ') into workspace ' || l_workspace || ' for schema ' || l_schema);
end;
/

@@dist/restaurant.sql

prompt RESTaurant is installed.
exit
