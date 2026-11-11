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
    ----------------------------------------------------------------------------
    -- module menu.v1 (partial)
    ----------------------------------------------------------------------------
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

    commit;
end;
/
