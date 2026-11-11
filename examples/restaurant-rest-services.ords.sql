--------------------------------------------------------------------------------
-- ORDS RESTful services, exported with RESTaurant
--
-- Run this script as the schema that owns the services. Existing modules,
-- templates and handlers of the same name are replaced.
--------------------------------------------------------------------------------
set define off

declare
    l_roles    owa.vc_arr;
    l_patterns owa.vc_arr;
    l_modules  owa.vc_arr;
begin
    ords.create_role(p_role_name => 'kitchen_staff');

    ----------------------------------------------------------------------------
    -- module kitchen.v1
    ----------------------------------------------------------------------------
    ords.define_module(
        p_module_name    => 'kitchen.v1',
        p_base_path      => '/kitchen/v1/',
        p_items_per_page => 50,
        p_status         => 'PUBLISHED',
        p_comments       => 'Back office services' );

    ords.define_template(
        p_module_name => 'kitchen.v1',
        p_pattern     => 'dishes/',
        p_priority    => 0,
        p_etag_type   => 'HASH',
        p_etag_query  => null,
        p_comments    => null );

    ords.define_handler(
        p_module_name    => 'kitchen.v1',
        p_pattern        => 'dishes/',
        p_method         => 'POST',
        p_source_type    => 'plsql/block',
        p_items_per_page => null,
        p_mimes_allowed  => 'application/json',
        p_comments       => null,
        p_source         => to_clob(q'[begin
    insert into dishes (name, course, price, vegetarian)
    values (:name, upper(:course), :price, nvl(:vegetarian, 'N'))
    returning dish_id into :id;

    :status   := 201;
    :location := 'dishes/' || :id;
end;]') );
    ords.define_parameter(
        p_module_name        => 'kitchen.v1',
        p_pattern            => 'dishes/',
        p_method             => 'POST',
        p_name               => 'Location',
        p_bind_variable_name => 'location',
        p_source_type        => 'HEADER',
        p_param_type         => 'STRING',
        p_access_method      => 'OUT',
        p_comments           => null );
    ords.define_parameter(
        p_module_name        => 'kitchen.v1',
        p_pattern            => 'dishes/',
        p_method             => 'POST',
        p_name               => 'X-ORDS-STATUS-CODE',
        p_bind_variable_name => 'status',
        p_source_type        => 'HEADER',
        p_param_type         => 'INT',
        p_access_method      => 'OUT',
        p_comments           => null );
    ords.define_parameter(
        p_module_name        => 'kitchen.v1',
        p_pattern            => 'dishes/',
        p_method             => 'POST',
        p_name               => 'id',
        p_bind_variable_name => 'id',
        p_source_type        => 'RESPONSE',
        p_param_type         => 'INT',
        p_access_method      => 'OUT',
        p_comments           => null );

    ords.define_template(
        p_module_name => 'kitchen.v1',
        p_pattern     => 'dishes/:id',
        p_priority    => 0,
        p_etag_type   => 'HASH',
        p_etag_query  => null,
        p_comments    => null );

    ords.define_handler(
        p_module_name    => 'kitchen.v1',
        p_pattern        => 'dishes/:id',
        p_method         => 'DELETE',
        p_source_type    => 'plsql/block',
        p_items_per_page => null,
        p_mimes_allowed  => null,
        p_comments       => null,
        p_source         => to_clob('begin
    delete from dishes where dish_id = :id;
    :status := case when sql%rowcount = 0 then 404 else 204 end;
end;') );
    ords.define_parameter(
        p_module_name        => 'kitchen.v1',
        p_pattern            => 'dishes/:id',
        p_method             => 'DELETE',
        p_name               => 'X-ORDS-STATUS-CODE',
        p_bind_variable_name => 'status',
        p_source_type        => 'HEADER',
        p_param_type         => 'INT',
        p_access_method      => 'OUT',
        p_comments           => null );

    ords.define_handler(
        p_module_name    => 'kitchen.v1',
        p_pattern        => 'dishes/:id',
        p_method         => 'PUT',
        p_source_type    => 'plsql/block',
        p_items_per_page => null,
        p_mimes_allowed  => 'application/json',
        p_comments       => null,
        p_source         => to_clob('begin
    update dishes
       set name       = nvl(:name, name),
           price      = nvl(:price, price),
           vegetarian = nvl(:vegetarian, vegetarian)
     where dish_id = :id;

    :status := case when sql%rowcount = 0 then 404 else 200 end;
end;') );
    ords.define_parameter(
        p_module_name        => 'kitchen.v1',
        p_pattern            => 'dishes/:id',
        p_method             => 'PUT',
        p_name               => 'X-ORDS-STATUS-CODE',
        p_bind_variable_name => 'status',
        p_source_type        => 'HEADER',
        p_param_type         => 'INT',
        p_access_method      => 'OUT',
        p_comments           => null );

    ords.define_template(
        p_module_name => 'kitchen.v1',
        p_pattern     => 'reservations/',
        p_priority    => 0,
        p_etag_type   => 'HASH',
        p_etag_query  => null,
        p_comments    => null );

    ords.define_handler(
        p_module_name    => 'kitchen.v1',
        p_pattern        => 'reservations/',
        p_method         => 'GET',
        p_source_type    => 'json/collection',
        p_items_per_page => null,
        p_mimes_allowed  => null,
        p_comments       => null,
        p_source         => to_clob('select reservation_id, guest_name, seats, reserved_for, status
  from reservations
 order by reserved_for') );

    ----------------------------------------------------------------------------
    -- module menu.v1
    ----------------------------------------------------------------------------
    ords.define_module(
        p_module_name    => 'menu.v1',
        p_base_path      => '/menu/v1/',
        p_items_per_page => 25,
        p_status         => 'PUBLISHED',
        p_comments       => 'Public menu of the restaurant' );

    ords.define_template(
        p_module_name => 'menu.v1',
        p_pattern     => 'dishes/',
        p_priority    => 0,
        p_etag_type   => 'HASH',
        p_etag_query  => null,
        p_comments    => 'All dishes' );

    ords.define_handler(
        p_module_name    => 'menu.v1',
        p_pattern        => 'dishes/',
        p_method         => 'GET',
        p_source_type    => 'json/collection',
        p_items_per_page => null,
        p_mimes_allowed  => null,
        p_comments       => 'Optional filter: ?course=MAIN',
        p_source         => to_clob('select dish_id, name, course, price, vegetarian
  from dishes
 where course = nvl(upper(:course), course)
 order by course, name') );
    ords.define_parameter(
        p_module_name        => 'menu.v1',
        p_pattern            => 'dishes/',
        p_method             => 'GET',
        p_name               => 'course',
        p_bind_variable_name => 'course',
        p_source_type        => 'URI',
        p_param_type         => 'STRING',
        p_access_method      => 'IN',
        p_comments           => 'STARTER, MAIN or DESSERT' );

    ords.define_template(
        p_module_name => 'menu.v1',
        p_pattern     => 'dishes/:id',
        p_priority    => 0,
        p_etag_type   => 'HASH',
        p_etag_query  => null,
        p_comments    => 'A single dish' );

    ords.define_handler(
        p_module_name    => 'menu.v1',
        p_pattern        => 'dishes/:id',
        p_method         => 'GET',
        p_source_type    => 'json/item',
        p_items_per_page => null,
        p_mimes_allowed  => null,
        p_comments       => null,
        p_source         => to_clob('select dish_id, name, course, price, vegetarian, created_on
  from dishes
 where dish_id = :id') );

    ----------------------------------------------------------------------------
    -- privilege kitchen.manage
    ----------------------------------------------------------------------------
    l_roles.delete;
    l_roles(1) := 'kitchen_staff';
    l_patterns.delete;
    l_patterns(1) := '/kitchen/internal/*';
    l_modules.delete;
    l_modules(1) := 'kitchen.v1';
    ords.define_privilege(
        p_privilege_name => 'kitchen.manage',
        p_roles          => l_roles,
        p_patterns       => l_patterns,
        p_modules        => l_modules,
        p_label          => 'Kitchen management',
        p_description    => 'Maintain dishes and see reservations',
        p_comments       => 'Sample privilege' );

    commit;
end;
/
