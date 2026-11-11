--------------------------------------------------------------------------------
-- RESTaurant Engine
--
-- All shared logic of the application lives in this anonymous block. It is
-- stored as a static application file and executed by the process plug-in
-- "RESTaurant Engine", so the application does not need any database objects
-- of its own. The engine only uses the documented ORDS PL/SQL API (package
-- ORDS) and the USER_ORDS_* dictionary views of the parsing schema.
--
-- Binds
--   :action   the operation to execute, see procedure RUN at the end
--   :prefix   prefix of the page items that carry the input and the results,
--             the item "<prefix>NAME" is referred to as NAME below
--   :message  success message of the operation (out)
--------------------------------------------------------------------------------
declare
    c_app_version    constant varchar2(20) := '1.1.0';
    c_format         constant varchar2(30) := 'restaurant-ords';
    c_format_version constant pls_integer  := 1;
    c_doc            constant varchar2(30) := 'RESTAURANT_DOC';
    c_plan           constant varchar2(30) := 'RESTAURANT_PLAN';
    c_check          constant varchar2(30) := 'RESTAURANT_CHECK';
    c_lf             constant varchar2(1)  := chr(10);
    c_cr             constant varchar2(1)  := chr(13);
    c_max_line       constant pls_integer  := 4000;
    -- a bind variable and the character in front of it
    c_bind           constant varchar2(60) := '(^|[^A-Za-z0-9_"''])(:[A-Za-z][A-Za-z0-9_$#]*)';

    e_user exception;
    pragma exception_init(e_user, -20999);

    type t_object_map is table of json_object_t index by varchar2(1000);
    type t_name_set   is table of boolean       index by varchar2(1000);

    g_prefix  varchar2(60);
    g_message varchar2(32767); -- success message of the action
    g_strict boolean := true; -- false while existing definitions are read

    --------------------------------------------------------------------------------
    -- basics
    --------------------------------------------------------------------------------
    procedure fail (p_message in varchar2) is
    begin
        raise_application_error(-20999, p_message);
    end fail;

    -- raises a validation error, but only for definitions that come from outside
    procedure invalid (p_message in varchar2) is
    begin
        if g_strict then
            fail(p_message);
        end if;
    end invalid;

    function item (p_name in varchar2) return varchar2 is
    begin
        return apex_util.get_session_state(g_prefix || p_name);
    end item;

    function item_clob (p_name in varchar2) return clob is
    begin
        return apex_session_state.get_clob(g_prefix || p_name);
    end item_clob;

    function item_number (p_name in varchar2, p_label in varchar2) return number is
    begin
        return to_number(trim(item(p_name)));
    exception
        when value_error or invalid_number then
            fail(p_label || ' must be a number.');
    end item_number;

    procedure set_item (p_name in varchar2, p_value in varchar2) is
    begin
        apex_util.set_session_state(g_prefix || p_name, p_value, false);
    end set_item;

    function is_yes (p_name in varchar2) return boolean is
    begin
        return nvl(item(p_name), 'N') = 'Y';
    end is_yes;

    function slug (p_text in varchar2) return varchar2 is
    begin
        return nvl(trim(both '-' from regexp_replace(lower(p_text), '[^a-z0-9._]+', '-')), 'unnamed');
    end slug;

    function schema_id return number is
        l_id number;
    begin
        select max(id) into l_id from user_ords_schemas;
        return l_id;
    end schema_id;

    --------------------------------------------------------------------------------
    -- JSON helpers
    --------------------------------------------------------------------------------
    procedure put (p_obj in out nocopy json_object_t, p_key in varchar2, p_value in varchar2) is
    begin
        if p_value is not null then
            p_obj.put(p_key, p_value);
        end if;
    end put;

    procedure put_number (p_obj in out nocopy json_object_t, p_key in varchar2, p_value in number) is
    begin
        if p_value is not null then
            p_obj.put(p_key, p_value);
        end if;
    end put_number;

    function as_object (p_element in json_element_t) return json_object_t is
    begin
        return treat(p_element as json_object_t);
    end as_object;

    function get_array (p_obj in json_object_t, p_key in varchar2) return json_array_t is
    begin
        if p_obj.has(p_key) and p_obj.get(p_key).is_array then
            return p_obj.get_array(p_key);
        end if;
        return json_array_t();
    end get_array;

    function get_text (p_obj in json_object_t, p_key in varchar2) return varchar2 is
        l_element json_element_t;
    begin
        if not p_obj.has(p_key) then
            return null;
        end if;
        l_element := p_obj.get(p_key);
        if l_element.is_null then
            return null;
        elsif l_element.is_number then
            return to_char(p_obj.get_number(p_key));
        elsif l_element.is_boolean then
            return case when p_obj.get_boolean(p_key) then 'true' else 'false' end;
        elsif l_element.is_string then
            return p_obj.get_string(p_key);
        end if;
        return null;
    end get_text;

    -- returns a copy of p_obj in which the array p_key is replaced by p_children
    function with_children (
        p_obj      in json_object_t,
        p_key      in varchar2,
        p_children in json_array_t )
        return json_object_t
    is
        l_result json_object_t := p_obj.clone;
    begin
        if l_result.has(p_key) then
            l_result.remove(p_key);
        end if;
        l_result.put(p_key, p_children);
        return l_result;
    end with_children;

    function same (p_left in json_object_t, p_right in json_object_t, p_without in varchar2 default null) return boolean is
        l_left  json_object_t := p_left.clone;
        l_right json_object_t := p_right.clone;
    begin
        if p_without is not null then
            if l_left.has(p_without)  then l_left.remove(p_without);  end if;
            if l_right.has(p_without) then l_right.remove(p_without); end if;
        end if;
        return dbms_lob.compare(l_left.to_clob, l_right.to_clob) = 0;
    end same;

    -- source code is stored as an array of lines, which keeps diffs readable
    function to_lines (p_text in clob) return json_array_t is
        l_lines json_array_t := json_array_t();
        l_len   pls_integer  := nvl(dbms_lob.getlength(p_text), 0);
        l_pos   pls_integer  := 1;
        l_next  pls_integer;
        l_line  varchar2(32767);
    begin
        while l_pos <= l_len + 1 loop
            l_next := case when l_pos > l_len then 0 else dbms_lob.instr(p_text, c_lf, l_pos) end;
            if l_next = 0 then
                l_next := l_len + 1;
            end if;
            if l_next - l_pos > c_max_line then
                return null; -- very long line, keep the text as one string
            end if;
            l_line := case when l_next > l_pos then rtrim(dbms_lob.substr(p_text, l_next - l_pos, l_pos), c_cr) end;
            if l_line is null then
                l_lines.append(json_array_t.parse('[""]').get(0)); -- an empty string, not null
            else
                l_lines.append(l_line);
            end if;
            l_pos := l_next + 1;
        end loop;
        return l_lines;
    end to_lines;

    procedure put_source (p_obj in out nocopy json_object_t, p_key in varchar2, p_text in clob) is
        l_lines json_array_t;
    begin
        if p_text is null or dbms_lob.getlength(p_text) = 0 then
            p_obj.put(p_key, json_array_t());
            return;
        end if;
        l_lines := to_lines(p_text);
        if l_lines is null then
            p_obj.put(p_key, replace(p_text, c_cr || c_lf, c_lf));
        else
            p_obj.put(p_key, l_lines);
        end if;
    end put_source;

    function get_source (p_obj in json_object_t, p_key in varchar2) return clob is
        l_element json_element_t;
        l_lines   json_array_t;
        l_text    clob;
        l_buffer  varchar2(32767);

        procedure flush is
        begin
            if l_buffer is not null then
                dbms_lob.writeappend(l_text, length(l_buffer), l_buffer);
                l_buffer := null;
            end if;
        end flush;
    begin
        if not p_obj.has(p_key) then
            return null;
        end if;
        l_element := p_obj.get(p_key);
        if l_element.is_string then
            return p_obj.get_clob(p_key);
        elsif not l_element.is_array then
            return null;
        end if;
        l_lines := p_obj.get_array(p_key);
        if l_lines.get_size = 0 then
            return null;
        end if;
        dbms_lob.createtemporary(l_text, true);
        for i in 0 .. l_lines.get_size - 1 loop
            if nvl(length(l_buffer), 0) > 16000 then
                flush;
            end if;
            l_buffer := l_buffer || case when i > 0 then c_lf end || l_lines.get_string(i);
        end loop;
        flush;
        return l_text;
    end get_source;

    --------------------------------------------------------------------------------
    -- canonical form
    --
    -- Every definition, whether it is read from the dictionary or from an import
    -- file, is brought into the same shape: fixed key order, defaults applied,
    -- children sorted by their natural key. Two definitions are equal when their
    -- canonical JSON is equal.
    --------------------------------------------------------------------------------
    function norm_parameter (p_param in json_object_t, p_context in varchar2) return json_object_t is
        l_result json_object_t := json_object_t();
        l_name   varchar2(4000) := get_text(p_param, 'name');
        l_value  varchar2(4000);
    begin
        if l_name is null then
            fail(p_context || ': a parameter has no name.');
        end if;
        l_result.put('name', l_name);
        put(l_result, 'bindVariable', get_text(p_param, 'bindVariable'));
        l_value := upper(nvl(get_text(p_param, 'sourceType'), 'HEADER'));
        if l_value not in ('HEADER', 'RESPONSE', 'URI') then
            invalid(p_context || ', parameter "' || l_name || '": unknown source type "' || l_value || '".');
        end if;
        l_result.put('sourceType', l_value);
        l_result.put('paramType', upper(nvl(get_text(p_param, 'paramType'), 'STRING')));
        l_value := upper(nvl(get_text(p_param, 'accessMethod'), 'IN'));
        if l_value not in ('IN', 'OUT', 'INOUT') then
            invalid(p_context || ', parameter "' || l_name || '": unknown access method "' || l_value || '".');
        end if;
        l_result.put('accessMethod', l_value);
        put(l_result, 'comments', get_text(p_param, 'comments'));
        return l_result;
    end norm_parameter;

    function norm_handler (p_handler in json_object_t, p_context in varchar2) return json_object_t is
        l_result      json_object_t := json_object_t();
        l_method      varchar2(4000) := upper(get_text(p_handler, 'method'));
        l_source_type varchar2(4000) := lower(get_text(p_handler, 'sourceType'));
        l_context     varchar2(4000);
        l_params      json_array_t := get_array(p_handler, 'parameters');
        l_sorted      json_array_t := json_array_t();
        l_map         t_object_map;
        l_binds       t_name_set;
        l_param       json_object_t;
        l_key         varchar2(1000);
    begin
        if l_method is null then
            fail(p_context || ': a handler has no method.');
        elsif l_method not in ('GET', 'POST', 'PUT', 'DELETE') then
            invalid(p_context || ': "' || l_method || '" is not a supported method. Use GET, POST, PUT or DELETE.');
        end if;
        l_context := p_context || ' ' || l_method;
        if l_source_type is null then
            fail(l_context || ': the source type is missing.');
        elsif l_source_type not in (
                  'json/collection', 'json/item', 'resource/lob', 'plsql/block', 'mle/javascript',
                  'json/query', 'csv/query', 'json/query;type=single', 'json/query;type=feed' )
        then
            invalid(l_context || ': unknown source type "' || l_source_type || '".');
        elsif l_method <> 'GET' and l_source_type not in ('plsql/block', 'mle/javascript') then
            invalid(l_context || ': a ' || l_method || ' handler needs the source type PL/SQL or MLE JavaScript.');
        end if;
        l_result.put('method', l_method);
        l_result.put('sourceType', l_source_type);
        put_number(l_result, 'itemsPerPage', p_handler.get_number('itemsPerPage'));
        put(l_result, 'mimesAllowed', get_text(p_handler, 'mimesAllowed'));
        put(l_result, 'mleEnvironment', get_text(p_handler, 'mleEnvironment'));
        put(l_result, 'comments', get_text(p_handler, 'comments'));
        put_source(l_result, 'source', get_source(p_handler, 'source'));
        if l_result.get('source').is_array and l_result.get_array('source').get_size = 0 then
            invalid(l_context || ': the handler has no source.');
        end if;
        for i in 0 .. l_params.get_size - 1 loop
            l_param := norm_parameter(as_object(l_params.get(i)), l_context);
            l_key   := l_param.get_string('name');
            if l_map.exists(l_key) then
                fail(l_context || ': parameter "' || l_key || '" is defined twice.');
            end if;
            if l_param.has('bindVariable') then
                if l_binds.exists(l_param.get_string('bindVariable')) then
                    fail(l_context || ': the bind variable "' || l_param.get_string('bindVariable') || '" is used by more than one parameter.');
                end if;
                l_binds(l_param.get_string('bindVariable')) := true;
            end if;
            l_map(l_key) := l_param;
        end loop;
        l_key := l_map.first;
        while l_key is not null loop
            l_sorted.append(l_map(l_key));
            l_key := l_map.next(l_key);
        end loop;
        l_result.put('parameters', l_sorted);
        return l_result;
    end norm_handler;

    function norm_template (p_template in json_object_t, p_context in varchar2) return json_object_t is
        l_result    json_object_t := json_object_t();
        l_uri       varchar2(4000) := trim(get_text(p_template, 'uriTemplate'));
        l_etag_type varchar2(4000) := upper(nvl(get_text(p_template, 'etagType'), 'HASH'));
        l_priority  number := nvl(p_template.get_number('priority'), 0);
        l_context   varchar2(4000);
        l_handlers  json_array_t := get_array(p_template, 'handlers');
        l_sorted    json_array_t := json_array_t();
        l_map       t_object_map;
        l_handler   json_object_t;
        l_key       varchar2(1000);
    begin
        if l_uri is null then
            fail(p_context || ': a template has no URI template.');
        end if;
        l_context := p_context || ', template "' || l_uri || '"';
        if l_etag_type not in ('HASH', 'QUERY', 'NONE') then
            invalid(l_context || ': unknown ETag type "' || l_etag_type || '".');
        elsif l_etag_type = 'QUERY' and get_text(p_template, 'etagQuery') is null then
            invalid(l_context || ': the ETag type QUERY needs an ETag query.');
        elsif l_priority not between 0 and 9 or l_priority <> trunc(l_priority) then
            invalid(l_context || ': the priority must be a whole number between 0 and 9.');
        end if;
        l_result.put('uriTemplate', l_uri);
        l_result.put('priority', l_priority);
        l_result.put('etagType', l_etag_type);
        if l_etag_type = 'QUERY' then
            put(l_result, 'etagQuery', get_text(p_template, 'etagQuery'));
        end if;
        put(l_result, 'comments', get_text(p_template, 'comments'));
        for i in 0 .. l_handlers.get_size - 1 loop
            l_handler := norm_handler(as_object(l_handlers.get(i)), l_context);
            l_key     := l_handler.get_string('method');
            if l_map.exists(l_key) then
                fail(l_context || ': the method ' || l_key || ' is defined twice.');
            end if;
            l_map(l_key) := l_handler;
        end loop;
        l_key := l_map.first;
        while l_key is not null loop
            l_sorted.append(l_map(l_key));
            l_key := l_map.next(l_key);
        end loop;
        l_result.put('handlers', l_sorted);
        return l_result;
    end norm_template;

    function norm_base_path (p_path in varchar2) return varchar2 is
        l_path varchar2(4000) := trim(p_path);
    begin
        if l_path is null then
            return null;
        end if;
        if substr(l_path, 1, 1) <> '/' then
            l_path := '/' || l_path;
        end if;
        if substr(l_path, -1) <> '/' then
            l_path := l_path || '/';
        end if;
        return l_path;
    end norm_base_path;

    function norm_module (p_module in json_object_t) return json_object_t is
        l_result    json_object_t := json_object_t();
        l_name      varchar2(4000) := trim(get_text(p_module, 'name'));
        l_base_path varchar2(4000) := norm_base_path(get_text(p_module, 'basePath'));
        l_status    varchar2(4000) := upper(nvl(get_text(p_module, 'status'), 'PUBLISHED'));
        l_ipp       number := nvl(p_module.get_number('itemsPerPage'), 25);
        l_context   varchar2(4000);
        l_templates json_array_t := get_array(p_module, 'templates');
        l_sorted    json_array_t := json_array_t();
        l_map       t_object_map;
        l_template  json_object_t;
        l_key       varchar2(1000);
    begin
        if l_name is null then
            fail('A module has no name.');
        end if;
        l_context := 'Module "' || l_name || '"';
        if length(l_name) > 255 then
            fail(l_context || ': the name is longer than 255 characters.');
        elsif l_base_path is null then
            fail(l_context || ': the base path is missing.');
        elsif l_status not in ('PUBLISHED', 'NOT_PUBLISHED') then
            invalid(l_context || ': unknown status "' || l_status || '".');
        elsif l_ipp < 0 or l_ipp <> trunc(l_ipp) then
            invalid(l_context || ': the pagination size must be a whole number.');
        end if;
        l_result.put('name', l_name);
        l_result.put('basePath', l_base_path);
        l_result.put('itemsPerPage', l_ipp);
        l_result.put('status', l_status);
        put(l_result, 'originsAllowed', get_text(p_module, 'originsAllowed'));
        put(l_result, 'comments', get_text(p_module, 'comments'));
        if p_module.has('partial') and p_module.get('partial').is_boolean and p_module.get_boolean('partial') then
            l_result.put('partial', true);
        end if;
        for i in 0 .. l_templates.get_size - 1 loop
            l_template := norm_template(as_object(l_templates.get(i)), l_context);
            l_key      := l_template.get_string('uriTemplate');
            if l_map.exists(l_key) then
                fail(l_context || ': the template "' || l_key || '" is defined twice.');
            end if;
            l_map(l_key) := l_template;
        end loop;
        l_key := l_map.first;
        while l_key is not null loop
            l_sorted.append(l_map(l_key));
            l_key := l_map.next(l_key);
        end loop;
        l_result.put('templates', l_sorted);
        return l_result;
    end norm_module;

    function norm_names (p_names in json_array_t) return json_array_t is
        l_set    t_name_set;
        l_result json_array_t := json_array_t();
        l_key    varchar2(1000);
    begin
        for i in 0 .. p_names.get_size - 1 loop
            if p_names.get(i).is_string and p_names.get_string(i) is not null then
                l_set(p_names.get_string(i)) := true;
            end if;
        end loop;
        l_key := l_set.first;
        while l_key is not null loop
            l_result.append(l_key);
            l_key := l_set.next(l_key);
        end loop;
        return l_result;
    end norm_names;

    function norm_privilege (p_privilege in json_object_t) return json_object_t is
        l_result json_object_t := json_object_t();
        l_name   varchar2(4000) := trim(get_text(p_privilege, 'name'));
    begin
        if l_name is null then
            fail('A privilege has no name.');
        elsif regexp_like(l_name, '\s') then
            invalid('Privilege "' || l_name || '": the name must not contain whitespace.');
        end if;
        l_result.put('name', l_name);
        put(l_result, 'label', get_text(p_privilege, 'label'));
        put(l_result, 'description', get_text(p_privilege, 'description'));
        put(l_result, 'comments', get_text(p_privilege, 'comments'));
        l_result.put('roles', norm_names(get_array(p_privilege, 'roles')));
        l_result.put('patterns', norm_names(get_array(p_privilege, 'patterns')));
        l_result.put('modules', norm_names(get_array(p_privilege, 'modules')));
        return l_result;
    end norm_privilege;

    --------------------------------------------------------------------------------
    -- snapshots of the current definitions
    --------------------------------------------------------------------------------
    function handler_object (p_handler_id in number) return json_object_t is
        l_handler json_object_t := json_object_t();
        l_params  json_array_t  := json_array_t();
        l_param   json_object_t;
    begin
        for h in ( select method, source_type, items_per_page, mimes_allowed, mle_env_name, comments, source
                     from user_ords_handlers
                    where id = p_handler_id )
        loop
            l_handler.put('method', h.method);
            l_handler.put('sourceType', h.source_type);
            put_number(l_handler, 'itemsPerPage', h.items_per_page);
            put(l_handler, 'mimesAllowed', h.mimes_allowed);
            put(l_handler, 'mleEnvironment', h.mle_env_name);
            put(l_handler, 'comments', h.comments);
            put_source(l_handler, 'source', h.source);
        end loop;
        for p in ( select name, bind_variable_name, source_type, param_type, access_method, comments
                     from user_ords_parameters
                    where handler_id = p_handler_id )
        loop
            l_param := json_object_t();
            l_param.put('name', p.name);
            put(l_param, 'bindVariable', p.bind_variable_name);
            l_param.put('sourceType', p.source_type);
            l_param.put('paramType', p.param_type);
            l_param.put('accessMethod', p.access_method);
            put(l_param, 'comments', p.comments);
            l_params.append(l_param);
        end loop;
        l_handler.put('parameters', l_params);
        return l_handler;
    end handler_object;

    function template_object (p_template_id in number, p_handler_id in number default null) return json_object_t is
        l_template json_object_t := json_object_t();
        l_handlers json_array_t  := json_array_t();
    begin
        for t in ( select uri_template, priority, etag_type, etag_query, comments
                     from user_ords_templates
                    where id = p_template_id )
        loop
            l_template.put('uriTemplate', t.uri_template);
            l_template.put('priority', t.priority);
            l_template.put('etagType', t.etag_type);
            put(l_template, 'etagQuery', t.etag_query);
            put(l_template, 'comments', t.comments);
        end loop;
        for h in ( select id
                     from user_ords_handlers
                    where template_id = p_template_id
                      and ( p_handler_id is null or id = p_handler_id ) )
        loop
            l_handlers.append(handler_object(h.id));
        end loop;
        l_template.put('handlers', l_handlers);
        return l_template;
    end template_object;

    -- the module in canonical form; with a template or handler id only that part
    -- of the module is returned and the module is marked as partial
    function module_object (
        p_module_id   in number,
        p_template_id in number default null,
        p_handler_id  in number default null )
        return json_object_t
    is
        l_module    json_object_t := json_object_t();
        l_templates json_array_t  := json_array_t();
        l_found     boolean := false;
    begin
        for m in ( select name, uri_prefix, items_per_page, status, origins_allowed, comments
                     from user_ords_modules
                    where id = p_module_id )
        loop
            l_found := true;
            l_module.put('name', m.name);
            l_module.put('basePath', m.uri_prefix);
            l_module.put('itemsPerPage', m.items_per_page);
            l_module.put('status', m.status);
            put(l_module, 'originsAllowed', m.origins_allowed);
            put(l_module, 'comments', m.comments);
        end loop;
        if not l_found then
            fail('The module does not exist any more.');
        end if;
        if p_template_id is not null or p_handler_id is not null then
            l_module.put('partial', true);
        end if;
        for t in ( select id
                     from user_ords_templates
                    where module_id = p_module_id
                      and ( p_template_id is null or id = p_template_id ) )
        loop
            l_templates.append(template_object(t.id, p_handler_id));
        end loop;
        l_module.put('templates', l_templates);
        g_strict := false;
        l_module := norm_module(l_module);
        g_strict := true;
        return l_module;
    end module_object;

    function privilege_object (p_privilege_id in number) return json_object_t is
        l_privilege json_object_t := json_object_t();
        l_names     json_array_t;
    begin
        for p in ( select name, label, description, comments
                     from user_ords_privileges
                    where id = p_privilege_id )
        loop
            l_privilege.put('name', p.name);
            put(l_privilege, 'label', p.label);
            put(l_privilege, 'description', p.description);
            put(l_privilege, 'comments', p.comments);
        end loop;
        l_names := json_array_t();
        for r in ( select role_name from user_ords_privilege_roles where privilege_id = p_privilege_id ) loop
            l_names.append(r.role_name);
        end loop;
        l_privilege.put('roles', l_names);
        l_names := json_array_t();
        for r in ( select pattern from user_ords_privilege_mappings where privilege_id = p_privilege_id ) loop
            l_names.append(r.pattern);
        end loop;
        l_privilege.put('patterns', l_names);
        l_names := json_array_t();
        for r in ( select module_name from user_ords_privilege_modules where privilege_id = p_privilege_id ) loop
            l_names.append(r.module_name);
        end loop;
        l_privilege.put('modules', l_names);
        g_strict := false;
        l_privilege := norm_privilege(l_privilege);
        g_strict := true;
        return l_privilege;
    end privilege_object;

    function module_id (p_name in varchar2) return number is
        l_id number;
    begin
        select max(id) into l_id from user_ords_modules where name = p_name;
        return l_id;
    end module_id;

    --------------------------------------------------------------------------------
    -- applying definitions through the ORDS API
    --------------------------------------------------------------------------------
    procedure apply_handler (p_module in varchar2, p_pattern in varchar2, p_handler in json_object_t) is
        l_method varchar2(10)  := p_handler.get_string('method');
        l_params json_array_t  := get_array(p_handler, 'parameters');
        l_param  json_object_t;
    begin
        ords.define_handler(
            p_module_name    => p_module,
            p_pattern        => p_pattern,
            p_method         => l_method,
            p_source_type    => p_handler.get_string('sourceType'),
            p_source         => get_source(p_handler, 'source'),
            p_items_per_page => p_handler.get_number('itemsPerPage'),
            p_mimes_allowed  => p_handler.get_string('mimesAllowed'),
            p_mle_env_name   => p_handler.get_string('mleEnvironment'),
            p_comments       => p_handler.get_string('comments') );
        for i in 0 .. l_params.get_size - 1 loop
            l_param := as_object(l_params.get(i));
            ords.define_parameter(
                p_module_name        => p_module,
                p_pattern            => p_pattern,
                p_method             => l_method,
                p_name               => l_param.get_string('name'),
                p_bind_variable_name => l_param.get_string('bindVariable'),
                p_source_type        => l_param.get_string('sourceType'),
                p_param_type         => l_param.get_string('paramType'),
                p_access_method      => l_param.get_string('accessMethod'),
                p_comments           => l_param.get_string('comments') );
        end loop;
    end apply_handler;

    procedure apply_template (p_module in varchar2, p_template in json_object_t) is
        l_pattern  varchar2(600) := p_template.get_string('uriTemplate');
        l_handlers json_array_t  := get_array(p_template, 'handlers');
    begin
        ords.define_template(
            p_module_name => p_module,
            p_pattern     => l_pattern,
            p_priority    => p_template.get_number('priority'),
            p_etag_type   => p_template.get_string('etagType'),
            p_etag_query  => p_template.get_string('etagQuery'),
            p_comments    => p_template.get_string('comments') );
        for i in 0 .. l_handlers.get_size - 1 loop
            apply_handler(p_module, l_pattern, as_object(l_handlers.get(i)));
        end loop;
    end apply_template;

    -- defines the module exactly as described, existing templates are replaced
    procedure apply_module (p_module in json_object_t) is
        l_name      varchar2(255) := p_module.get_string('name');
        l_templates json_array_t  := get_array(p_module, 'templates');
    begin
        ords.define_module(
            p_module_name    => l_name,
            p_base_path      => p_module.get_string('basePath'),
            p_items_per_page => p_module.get_number('itemsPerPage'),
            p_status         => p_module.get_string('status'),
            p_comments       => p_module.get_string('comments') );
        ords.set_module_origins_allowed(
            p_module_name     => l_name,
            p_origins_allowed => p_module.get_string('originsAllowed') );
        for i in 0 .. l_templates.get_size - 1 loop
            apply_template(l_name, as_object(l_templates.get(i)));
        end loop;
    end apply_module;

    function to_vc_arr (p_names in json_array_t) return owa.vc_arr is
        l_result owa.vc_arr;
    begin
        for i in 0 .. p_names.get_size - 1 loop
            l_result(i + 1) := p_names.get_string(i);
        end loop;
        return l_result;
    end to_vc_arr;

    -- defines a privilege; module links of an existing privilege are kept and
    -- modules that do not exist in this schema are ignored
    procedure apply_privilege (p_privilege in json_object_t) is
        l_name    varchar2(255) := p_privilege.get_string('name');
        l_modules json_array_t  := json_array_t();
        l_wanted  json_array_t  := get_array(p_privilege, 'modules');
        l_set     t_name_set;
        l_key     varchar2(1000);
    begin
        for i in 0 .. l_wanted.get_size - 1 loop
            if module_id(l_wanted.get_string(i)) is not null then
                l_set(l_wanted.get_string(i)) := true;
            end if;
        end loop;
        for m in ( select pm.module_name
                     from user_ords_privilege_modules pm
                    where pm.privilege_name = l_name )
        loop
            l_set(m.module_name) := true;
        end loop;
        l_key := l_set.first;
        while l_key is not null loop
            l_modules.append(l_key);
            l_key := l_set.next(l_key);
        end loop;
        ords.define_privilege(
            p_privilege_name => l_name,
            p_roles          => to_vc_arr(get_array(p_privilege, 'roles')),
            p_patterns       => to_vc_arr(get_array(p_privilege, 'patterns')),
            p_modules        => to_vc_arr(l_modules),
            p_label          => p_privilege.get_string('label'),
            p_description    => p_privilege.get_string('description'),
            p_comments       => p_privilege.get_string('comments') );
    end apply_privilege;

    --------------------------------------------------------------------------------
    -- merging an incoming module into an existing one
    --------------------------------------------------------------------------------
    function merge_template (p_existing in json_object_t, p_incoming in json_object_t) return json_object_t is
        l_map      t_object_map;
        l_handlers json_array_t := get_array(p_existing, 'handlers');
        l_result   json_array_t := json_array_t();
        l_key      varchar2(1000);
    begin
        for i in 0 .. l_handlers.get_size - 1 loop
            l_map(as_object(l_handlers.get(i)).get_string('method')) := as_object(l_handlers.get(i));
        end loop;
        l_handlers := get_array(p_incoming, 'handlers');
        for i in 0 .. l_handlers.get_size - 1 loop
            l_map(as_object(l_handlers.get(i)).get_string('method')) := as_object(l_handlers.get(i));
        end loop;
        l_key := l_map.first;
        while l_key is not null loop
            l_result.append(l_map(l_key));
            l_key := l_map.next(l_key);
        end loop;
        return with_children(p_incoming, 'handlers', l_result);
    end merge_template;

    function merge_module (p_existing in json_object_t, p_incoming in json_object_t) return json_object_t is
        l_partial   boolean := p_incoming.has('partial');
        l_map       t_object_map;
        l_templates json_array_t := get_array(p_existing, 'templates');
        l_template  json_object_t;
        l_result    json_array_t := json_array_t();
        l_module    json_object_t;
        l_key       varchar2(1000);
    begin
        for i in 0 .. l_templates.get_size - 1 loop
            l_map(as_object(l_templates.get(i)).get_string('uriTemplate')) := as_object(l_templates.get(i));
        end loop;
        l_templates := get_array(p_incoming, 'templates');
        for i in 0 .. l_templates.get_size - 1 loop
            l_template := as_object(l_templates.get(i));
            l_key      := l_template.get_string('uriTemplate');
            if l_map.exists(l_key) then
                l_map(l_key) := merge_template(l_map(l_key), l_template);
            else
                l_map(l_key) := l_template;
            end if;
        end loop;
        l_key := l_map.first;
        while l_key is not null loop
            l_result.append(l_map(l_key));
            l_key := l_map.next(l_key);
        end loop;
        -- a partial export carries the module attributes only as context
        l_module := with_children(case when l_partial then p_existing else p_incoming end, 'templates', l_result);
        if l_module.has('partial') then
            l_module.remove('partial');
        end if;
        return l_module;
    end merge_module;

    -- brings an existing module in line with an incoming one and only touches what
    -- differs; templates and handlers that exist only in the schema are kept
    procedure apply_changes (p_existing in json_object_t, p_incoming in json_object_t) is
        l_name      varchar2(255) := p_existing.get_string('name');
        l_old_map   t_object_map;
        l_old_hmap  t_object_map;
        l_array     json_array_t  := get_array(p_existing, 'templates');
        l_templates json_array_t  := get_array(p_incoming, 'templates');
        l_template  json_object_t;
        l_handlers  json_array_t;
        l_handler   json_object_t;
        l_key       varchar2(1000);
        l_method    varchar2(10);
    begin
        if not p_incoming.has('partial') and not same(p_existing, p_incoming, 'templates') then
            -- module attributes can only be set by defining the whole module again
            apply_module(merge_module(p_existing, p_incoming));
            return;
        end if;
        for i in 0 .. l_array.get_size - 1 loop
            l_old_map(as_object(l_array.get(i)).get_string('uriTemplate')) := as_object(l_array.get(i));
        end loop;
        for t in 0 .. l_templates.get_size - 1 loop
            l_template := as_object(l_templates.get(t));
            l_key      := l_template.get_string('uriTemplate');
            if not l_old_map.exists(l_key) then
                apply_template(l_name, l_template);
            elsif not same(l_old_map(l_key), l_template, 'handlers') then
                apply_template(l_name, merge_template(l_old_map(l_key), l_template));
            else
                l_old_hmap.delete;
                l_array := get_array(l_old_map(l_key), 'handlers');
                for h in 0 .. l_array.get_size - 1 loop
                    l_old_hmap(as_object(l_array.get(h)).get_string('method')) := as_object(l_array.get(h));
                end loop;
                l_handlers := get_array(l_template, 'handlers');
                for h in 0 .. l_handlers.get_size - 1 loop
                    l_handler := as_object(l_handlers.get(h));
                    l_method  := l_handler.get_string('method');
                    if not l_old_hmap.exists(l_method) or not same(l_old_hmap(l_method), l_handler) then
                        apply_handler(l_name, l_key, l_handler);
                    end if;
                end loop;
            end if;
        end loop;
    end apply_changes;

    --------------------------------------------------------------------------------
    -- documents (the exchange format)
    --------------------------------------------------------------------------------
    function new_document (p_with_meta in boolean) return json_object_t is
        l_doc  json_object_t := json_object_t();
        l_meta json_object_t := json_object_t();
    begin
        l_doc.put('format', c_format);
        l_doc.put('version', c_format_version);
        if p_with_meta then
            l_meta.put('generator', 'RESTaurant ' || c_app_version);
            l_meta.put('exportedAt', to_char(sys_extract_utc(systimestamp), 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
            l_meta.put('schema', sys_context('userenv', 'current_schema'));
            l_meta.put('ordsVersion', ords.installed_version);
            l_doc.put('meta', l_meta);
        end if;
        return l_doc;
    end new_document;

    function is_user_defined (p_name in varchar2, p_schema_id in number) return boolean is
    begin
        return p_schema_id = schema_id and p_name not like 'oracle.%';
    end is_user_defined;

    -- adds roles and privileges; p_module_names limits the privileges to those
    -- that protect one of the given modules (null = all of the schema)
    procedure add_security (p_doc in out nocopy json_object_t, p_module_names in t_name_set, p_all in boolean) is
        l_privileges json_array_t := json_array_t();
        l_roles      t_name_set;
        l_role_array json_array_t := json_array_t();
        l_privilege  json_object_t;
        l_names      json_array_t;
        l_take       boolean;
        l_key        varchar2(1000);
    begin
        for p in ( select id, name, schema_id from user_ords_privileges order by name ) loop
            if is_user_defined(p.name, p.schema_id) then
                l_take := p_all;
                if not l_take then
                    for m in ( select module_name from user_ords_privilege_modules where privilege_id = p.id ) loop
                        l_take := l_take or p_module_names.exists(m.module_name);
                    end loop;
                end if;
                if l_take then
                    l_privilege := privilege_object(p.id);
                    l_privileges.append(l_privilege);
                    l_names := get_array(l_privilege, 'roles');
                    for i in 0 .. l_names.get_size - 1 loop
                        l_roles(l_names.get_string(i)) := true;
                    end loop;
                end if;
            end if;
        end loop;
        for r in ( select name, schema_id from user_ords_roles ) loop
            if is_user_defined(r.name, r.schema_id) and ( p_all or l_roles.exists(r.name) ) then
                l_roles(r.name) := true;
            elsif l_roles.exists(r.name) then
                l_roles.delete(r.name); -- built-in roles exist everywhere
            end if;
        end loop;
        l_key := l_roles.first;
        while l_key is not null loop
            l_role_array.append(l_key);
            l_key := l_roles.next(l_key);
        end loop;
        p_doc.put('roles', l_role_array);
        p_doc.put('privileges', l_privileges);
    end add_security;

    -- serializes a document with a fixed layout (two spaces, one value per line),
    -- so that exports are identical on every database version
    function pretty (p_doc in json_object_t) return clob is
        l_out    clob;
        l_buffer varchar2(32767);

        procedure flush is
        begin
            if l_buffer is not null then
                dbms_lob.writeappend(l_out, length(l_buffer), l_buffer);
                l_buffer := null;
            end if;
        end flush;

        procedure emit (p_text in varchar2) is
        begin
            if nvl(lengthb(l_buffer), 0) + nvl(lengthb(p_text), 0) > 32000 then
                flush;
            end if;
            l_buffer := l_buffer || p_text;
        end emit;

        function escaped (p_text in varchar2) return varchar2 is
            l_text varchar2(32767) := replace(replace(p_text, '\', '\\'), '"', '\"');
        begin
            if regexp_like(l_text, '[[:cntrl:]]') then
                l_text := replace(replace(replace(l_text, c_lf, '\n'), c_cr, '\r'), chr(9), '\t');
                for i in 0 .. 31 loop
                    l_text := replace(l_text, chr(i), '\u00' || to_char(i, 'fm0x'));
                end loop;
            end if;
            return l_text;
        end escaped;

        procedure write (p_element in json_element_t, p_level in pls_integer) is
            l_pad    varchar2(200) := rpad(' ', p_level * 2);
            l_object json_object_t;
            l_array  json_array_t;
            l_keys   json_key_list;
            l_scalar clob;
            l_pos    pls_integer := 1;
        begin
            if p_element.is_object then
                l_object := treat(p_element as json_object_t);
                l_keys   := l_object.get_keys;
                if l_keys is null or l_keys.count = 0 then
                    emit('{}');
                    return;
                end if;
                emit('{' || c_lf);
                for i in 1 .. l_keys.count loop
                    emit(l_pad || '  "' || l_keys(i) || '": ');
                    write(l_object.get(l_keys(i)), p_level + 1);
                    emit(case when i < l_keys.count then ',' end || c_lf);
                end loop;
                emit(l_pad || '}');
            elsif p_element.is_array then
                l_array := treat(p_element as json_array_t);
                if l_array.get_size = 0 then
                    emit('[]');
                    return;
                end if;
                emit('[' || c_lf);
                for i in 0 .. l_array.get_size - 1 loop
                    emit(l_pad || '  ');
                    write(l_array.get(i), p_level + 1);
                    emit(case when i < l_array.get_size - 1 then ',' end || c_lf);
                end loop;
                emit(l_pad || ']');
            elsif p_element.is_string then
                l_scalar := p_element.to_clob;
                emit('"');
                while l_pos <= nvl(dbms_lob.getlength(l_scalar), 0) loop
                    emit(escaped(dbms_lob.substr(l_scalar, 4000, l_pos)));
                    l_pos := l_pos + 4000;
                end loop;
                emit('"');
            else
                emit(p_element.to_string);
            end if;
        end write;
    begin
        dbms_lob.createtemporary(l_out, true);
        write(p_doc, 0);
        emit(c_lf);
        flush;
        return l_out;
    end pretty;

    -- builds the export document for the scope given by the page items
    --   SCOPE   SCHEMA | MODULES | MODULE | TEMPLATE | HANDLER
    --   ID      id of the module, template or handler
    --   MODULES colon separated module ids (scope MODULES)
    procedure build_export (p_doc out nocopy json_object_t, p_name out varchar2) is
        l_scope    varchar2(30) := nvl(item('SCOPE'), 'SCHEMA');
        l_id       number := to_number(item('ID'));
        l_modules  json_array_t := json_array_t();
        l_names    t_name_set;
        l_module   json_object_t;
        l_ids      apex_t_number;
    begin
        p_doc := new_document(p_with_meta => is_yes('INCLUDE_META'));
        if l_scope = 'SCHEMA' then
            for m in ( select id from user_ords_modules order by name ) loop
                l_modules.append(module_object(m.id));
            end loop;
            p_name := slug(sys_context('userenv', 'current_schema')) || '-rest-services';
        elsif l_scope = 'MODULES' then
            l_ids := apex_string.split_numbers(item('MODULES'), ':');
            for m in ( select id, name from user_ords_modules
                        where id in ( select column_value from table(l_ids) )
                        order by name )
            loop
                l_modules.append(module_object(m.id));
                p_name := case when p_name is null then slug(m.name) else slug(sys_context('userenv', 'current_schema')) || '-rest-services' end;
            end loop;
            if l_modules.get_size = 0 then
                fail('Select at least one module to export.');
            end if;
        elsif l_scope = 'MODULE' then
            l_module := module_object(l_id);
            l_modules.append(l_module);
            p_name := slug(l_module.get_string('name'));
        elsif l_scope = 'TEMPLATE' then
            for t in ( select t.id, t.module_id, t.uri_template, m.name
                         from user_ords_templates t
                         join user_ords_modules m on m.id = t.module_id
                        where t.id = l_id )
            loop
                l_modules.append(module_object(t.module_id, p_template_id => t.id));
                p_name := slug(t.name) || '--' || slug(t.uri_template);
            end loop;
        elsif l_scope = 'HANDLER' then
            for h in ( select h.id, h.method, t.id template_id, t.module_id, t.uri_template, m.name
                         from user_ords_handlers h
                         join user_ords_templates t on t.id = h.template_id
                         join user_ords_modules m on m.id = t.module_id
                        where h.id = l_id )
            loop
                l_modules.append(module_object(h.module_id, p_template_id => h.template_id, p_handler_id => h.id));
                p_name := slug(h.name) || '--' || slug(h.uri_template) || '--' || lower(h.method);
            end loop;
        else
            fail('Unknown export scope "' || l_scope || '".');
        end if;
        if l_modules.get_size = 0 then
            if l_scope = 'SCHEMA' then
                null; -- an empty schema is a valid export
            else
                fail('The element to export does not exist any more.');
            end if;
        end if;
        if is_yes('INCLUDE_SECURITY') and l_scope in ('SCHEMA', 'MODULES', 'MODULE') then
            for i in 0 .. l_modules.get_size - 1 loop
                l_names(as_object(l_modules.get(i)).get_string('name')) := true;
            end loop;
            add_security(p_doc, l_names, p_all => l_scope = 'SCHEMA');
        end if;
        p_doc.put('modules', l_modules);
    end build_export;

    --------------------------------------------------------------------------------
    -- SQL script generation
    --------------------------------------------------------------------------------
    function literal (p_text in varchar2) return varchar2 is
        type t_pairs is varray(8) of varchar2(2);
        l_pairs t_pairs := t_pairs('[]', '{}', '()', '<>', '~~', '!!', '^^', '||');
    begin
        if p_text is null then
            return 'null';
        elsif instr(p_text, '''') = 0 then
            return '''' || p_text || '''';
        end if;
        for i in 1 .. l_pairs.count loop
            if instr(p_text, substr(l_pairs(i), 2, 1) || '''') = 0 then
                return 'q''' || substr(l_pairs(i), 1, 1) || p_text || substr(l_pairs(i), 2, 1) || '''';
            end if;
        end loop;
        return '''' || replace(p_text, '''', '''''') || '''';
    end literal;

    procedure append (p_script in out nocopy clob, p_text in varchar2) is
    begin
        if p_text is not null then
            dbms_lob.writeappend(p_script, length(p_text), p_text);
        end if;
    end append;

    procedure append_line (p_script in out nocopy clob, p_text in varchar2 default null) is
    begin
        append(p_script, p_text || c_lf);
    end append_line;

    -- writes source code as an expression of string literals; lines that SQL*Plus
    -- or SQLcl would interpret on their own never start a line of the script
    procedure append_source (p_script in out nocopy clob, p_handler in json_object_t, p_indent in varchar2) is
        l_element json_element_t := p_handler.get('source');
        l_lines   json_array_t;
        l_text    clob;
        l_chunk   varchar2(32767);
        l_first   boolean := true;
        l_safe    boolean := true;
        l_len     pls_integer;
        l_pos     pls_integer := 1;

        procedure emit (p_literal in varchar2) is
        begin
            append(p_script, case when l_first then 'to_clob(' else c_lf || p_indent || '|| to_clob(' end || p_literal || ')');
            l_first := false;
        end emit;
    begin
        if l_element.is_array then
            l_lines := p_handler.get_array('source');
            if l_lines.get_size = 0 then
                append(p_script, 'null');
                return;
            end if;
            for i in 0 .. l_lines.get_size - 1 loop
                if i > 0 and regexp_like(l_lines.get_string(i), '^(\s*[/.]\s*$|#)') then
                    l_safe := false;
                end if;
            end loop;
            if l_safe then
                -- readable form: the code as multi line literals of moderate size
                for i in 0 .. l_lines.get_size - 1 loop
                    if nvl(length(l_chunk), 0) + nvl(length(l_lines.get_string(i)), 0) > 3000 then
                        emit(literal(l_chunk || c_lf));
                        l_chunk := l_lines.get_string(i);
                    else
                        l_chunk := l_chunk || case when i > 0 then c_lf end || l_lines.get_string(i);
                    end if;
                end loop;
                emit(literal(l_chunk));
            else
                -- defensive form: one literal per line
                for i in 0 .. l_lines.get_size - 1 loop
                    emit(literal(l_lines.get_string(i)) || case when i < l_lines.get_size - 1 then ' || chr(10)' end);
                end loop;
            end if;
        else
            l_text := p_handler.get_clob('source');
            l_len  := dbms_lob.getlength(l_text);
            while l_pos <= l_len loop
                emit('''' || replace(replace(dbms_lob.substr(l_text, 2000, l_pos), '''', ''''''), c_lf, ''' || chr(10) || ''') || '''');
                l_pos := l_pos + 2000;
            end loop;
        end if;
    end append_source;

    function sql_script (p_doc in json_object_t) return clob is
        l_script     clob;
        l_roles      json_array_t := get_array(p_doc, 'roles');
        l_privileges json_array_t := get_array(p_doc, 'privileges');
        l_modules    json_array_t := get_array(p_doc, 'modules');
        l_module     json_object_t;
        l_templates  json_array_t;
        l_template   json_object_t;
        l_handlers   json_array_t;
        l_handler    json_object_t;
        l_params     json_array_t;
        l_param      json_object_t;
        l_privilege  json_object_t;
        l_name       varchar2(255);
        l_pattern    varchar2(600);
        l_partial    boolean;

        procedure name_array (p_variable in varchar2, p_names in json_array_t) is
        begin
            append_line(l_script, '    ' || p_variable || '.delete;');
            for i in 0 .. p_names.get_size - 1 loop
                append_line(l_script, '    ' || p_variable || '(' || (i + 1) || ') := ' || literal(p_names.get_string(i)) || ';');
            end loop;
        end name_array;
    begin
        dbms_lob.createtemporary(l_script, true);
        append_line(l_script, '--------------------------------------------------------------------------------');
        append_line(l_script, '-- ORDS RESTful services, exported with RESTaurant');
        if p_doc.has('meta') then
            append_line(l_script, '-- Schema   : ' || p_doc.get_object('meta').get_string('schema'));
            append_line(l_script, '-- Exported : ' || p_doc.get_object('meta').get_string('exportedAt'));
            append_line(l_script, '-- ORDS     : ' || p_doc.get_object('meta').get_string('ordsVersion'));
        end if;
        append_line(l_script, '--');
        append_line(l_script, '-- Run this script as the schema that owns the services. Existing modules,');
        append_line(l_script, '-- templates and handlers of the same name are replaced.');
        append_line(l_script, '--------------------------------------------------------------------------------');
        append_line(l_script, 'set define off');
        append_line(l_script);
        append_line(l_script, 'declare');
        append_line(l_script, '    l_roles    owa.vc_arr;');
        append_line(l_script, '    l_patterns owa.vc_arr;');
        append_line(l_script, '    l_modules  owa.vc_arr;');
        append_line(l_script, 'begin');
        for i in 0 .. l_roles.get_size - 1 loop
            append_line(l_script, '    ords.create_role(p_role_name => ' || literal(l_roles.get_string(i)) || ');');
        end loop;
        if l_roles.get_size > 0 then
            append_line(l_script);
        end if;
        for m in 0 .. l_modules.get_size - 1 loop
            l_module  := as_object(l_modules.get(m));
            l_name    := l_module.get_string('name');
            l_partial := l_module.has('partial');
            append_line(l_script, '    ----------------------------------------------------------------------------');
            append_line(l_script, '    -- module ' || l_name || case when l_partial then ' (partial)' end);
            append_line(l_script, '    ----------------------------------------------------------------------------');
            if not l_partial then
                append_line(l_script, '    ords.define_module(');
                append_line(l_script, '        p_module_name    => ' || literal(l_name) || ',');
                append_line(l_script, '        p_base_path      => ' || literal(l_module.get_string('basePath')) || ',');
                append_line(l_script, '        p_items_per_page => ' || l_module.get_number('itemsPerPage') || ',');
                append_line(l_script, '        p_status         => ' || literal(l_module.get_string('status')) || ',');
                append_line(l_script, '        p_comments       => ' || literal(l_module.get_string('comments')) || ' );');
                if l_module.has('originsAllowed') then
                    append_line(l_script, '    ords.set_module_origins_allowed(');
                    append_line(l_script, '        p_module_name     => ' || literal(l_name) || ',');
                    append_line(l_script, '        p_origins_allowed => ' || literal(l_module.get_string('originsAllowed')) || ' );');
                end if;
                append_line(l_script);
            end if;
            l_templates := get_array(l_module, 'templates');
            for t in 0 .. l_templates.get_size - 1 loop
                l_template := as_object(l_templates.get(t));
                l_pattern  := l_template.get_string('uriTemplate');
                l_handlers := get_array(l_template, 'handlers');
                -- a single handler export must not replace the other handlers of its template
                if not ( l_partial and l_handlers.get_size = 1 and item('SCOPE') = 'HANDLER' ) then
                    append_line(l_script, '    ords.define_template(');
                    append_line(l_script, '        p_module_name => ' || literal(l_name) || ',');
                    append_line(l_script, '        p_pattern     => ' || literal(l_pattern) || ',');
                    append_line(l_script, '        p_priority    => ' || l_template.get_number('priority') || ',');
                    append_line(l_script, '        p_etag_type   => ' || literal(l_template.get_string('etagType')) || ',');
                    append_line(l_script, '        p_etag_query  => ' || literal(l_template.get_string('etagQuery')) || ',');
                    append_line(l_script, '        p_comments    => ' || literal(l_template.get_string('comments')) || ' );');
                    append_line(l_script);
                end if;
                for h in 0 .. l_handlers.get_size - 1 loop
                    l_handler := as_object(l_handlers.get(h));
                    append_line(l_script, '    ords.define_handler(');
                    append_line(l_script, '        p_module_name    => ' || literal(l_name) || ',');
                    append_line(l_script, '        p_pattern        => ' || literal(l_pattern) || ',');
                    append_line(l_script, '        p_method         => ' || literal(l_handler.get_string('method')) || ',');
                    append_line(l_script, '        p_source_type    => ' || literal(l_handler.get_string('sourceType')) || ',');
                    append_line(l_script, '        p_items_per_page => ' || nvl(to_char(l_handler.get_number('itemsPerPage')), 'null') || ',');
                    append_line(l_script, '        p_mimes_allowed  => ' || literal(l_handler.get_string('mimesAllowed')) || ',');
                    if l_handler.has('mleEnvironment') then
                        append_line(l_script, '        p_mle_env_name   => ' || literal(l_handler.get_string('mleEnvironment')) || ',');
                    end if;
                    append_line(l_script, '        p_comments       => ' || literal(l_handler.get_string('comments')) || ',');
                    append(l_script, '        p_source         => ');
                    append_source(l_script, l_handler, '                            ');
                    append_line(l_script, ' );');
                    l_params := get_array(l_handler, 'parameters');
                    for p in 0 .. l_params.get_size - 1 loop
                        l_param := as_object(l_params.get(p));
                        append_line(l_script, '    ords.define_parameter(');
                        append_line(l_script, '        p_module_name        => ' || literal(l_name) || ',');
                        append_line(l_script, '        p_pattern            => ' || literal(l_pattern) || ',');
                        append_line(l_script, '        p_method             => ' || literal(l_handler.get_string('method')) || ',');
                        append_line(l_script, '        p_name               => ' || literal(l_param.get_string('name')) || ',');
                        append_line(l_script, '        p_bind_variable_name => ' || literal(l_param.get_string('bindVariable')) || ',');
                        append_line(l_script, '        p_source_type        => ' || literal(l_param.get_string('sourceType')) || ',');
                        append_line(l_script, '        p_param_type         => ' || literal(l_param.get_string('paramType')) || ',');
                        append_line(l_script, '        p_access_method      => ' || literal(l_param.get_string('accessMethod')) || ',');
                        append_line(l_script, '        p_comments           => ' || literal(l_param.get_string('comments')) || ' );');
                    end loop;
                    append_line(l_script);
                end loop;
            end loop;
        end loop;
        for i in 0 .. l_privileges.get_size - 1 loop
            l_privilege := as_object(l_privileges.get(i));
            append_line(l_script, '    ----------------------------------------------------------------------------');
            append_line(l_script, '    -- privilege ' || l_privilege.get_string('name'));
            append_line(l_script, '    ----------------------------------------------------------------------------');
            name_array('l_roles', get_array(l_privilege, 'roles'));
            name_array('l_patterns', get_array(l_privilege, 'patterns'));
            name_array('l_modules', get_array(l_privilege, 'modules'));
            append_line(l_script, '    ords.define_privilege(');
            append_line(l_script, '        p_privilege_name => ' || literal(l_privilege.get_string('name')) || ',');
            append_line(l_script, '        p_roles          => l_roles,');
            append_line(l_script, '        p_patterns       => l_patterns,');
            append_line(l_script, '        p_modules        => l_modules,');
            append_line(l_script, '        p_label          => ' || literal(l_privilege.get_string('label')) || ',');
            append_line(l_script, '        p_description    => ' || literal(l_privilege.get_string('description')) || ',');
            append_line(l_script, '        p_comments       => ' || literal(l_privilege.get_string('comments')) || ' );');
            append_line(l_script);
        end loop;
        append_line(l_script, '    commit;');
        append_line(l_script, 'end;');
        append_line(l_script, '/');
        return l_script;
    end sql_script;

    --------------------------------------------------------------------------------
    -- export
    --------------------------------------------------------------------------------
    procedure download (p_content in out nocopy blob, p_file_name in varchar2, p_mime_type in varchar2) is
    begin
        sys.htp.init;
        sys.owa_util.mime_header(p_mime_type, false);
        sys.htp.p('Content-Length: ' || dbms_lob.getlength(p_content));
        sys.htp.p('Content-Disposition: attachment; filename="' || p_file_name || '"');
        sys.htp.p('Cache-Control: no-store');
        sys.owa_util.http_header_close;
        sys.wpg_docload.download_file(p_content);
        apex_application.stop_apex_engine;
    end download;

    function single_module_document (p_doc in json_object_t, p_module in json_object_t) return json_object_t is
        l_doc     json_object_t := json_object_t();
        l_modules json_array_t  := json_array_t();
    begin
        l_doc.put('format', c_format);
        l_doc.put('version', c_format_version);
        if p_doc.has('meta') then
            l_doc.put('meta', p_doc.get_object('meta'));
        end if;
        l_modules.append(p_module);
        l_doc.put('modules', l_modules);
        return l_doc;
    end single_module_document;

    -- FORMAT: JSON | SQL | ZIP (one JSON file per module plus security.ords.json)
    procedure export_content (p_content out nocopy clob, p_file_name out varchar2, p_zip out nocopy blob) is
        l_doc      json_object_t;
        l_name     varchar2(1000);
        l_format   varchar2(10) := nvl(item('FORMAT'), 'JSON');
        l_modules  json_array_t;
        l_module   json_object_t;
        l_security json_object_t;
    begin
        build_export(l_doc, l_name);
        if l_format = 'SQL' then
            p_content   := sql_script(l_doc);
            p_file_name := l_name || '.ords.sql';
        elsif l_format = 'ZIP' then
            l_modules := get_array(l_doc, 'modules');
            for i in 0 .. l_modules.get_size - 1 loop
                l_module := as_object(l_modules.get(i));
                apex_zip.add_file(
                    p_zipped_blob => p_zip,
                    p_file_name   => 'modules/' || slug(l_module.get_string('name')) || '.ords.json',
                    p_content     => apex_util.clob_to_blob(pretty(single_module_document(l_doc, l_module)), 'AL32UTF8') );
            end loop;
            if l_doc.has('privileges') then
                l_security := json_object_t();
                l_security.put('format', c_format);
                l_security.put('version', c_format_version);
                l_security.put('roles', get_array(l_doc, 'roles'));
                l_security.put('privileges', get_array(l_doc, 'privileges'));
                l_security.put('modules', json_array_t());
                apex_zip.add_file(
                    p_zipped_blob => p_zip,
                    p_file_name   => 'security.ords.json',
                    p_content     => apex_util.clob_to_blob(pretty(l_security), 'AL32UTF8') );
            end if;
            if p_zip is null then
                fail('There is nothing to export.');
            end if;
            apex_zip.finish(p_zipped_blob => p_zip);
            p_file_name := l_name || '.ords.zip';
        else
            p_content   := pretty(l_doc);
            p_file_name := l_name || '.ords.json';
        end if;
    end export_content;

    procedure export_download is
        l_content   clob;
        l_file_name varchar2(1000);
        l_blob      blob;
    begin
        export_content(l_content, l_file_name, l_blob);
        if l_blob is not null then
            download(l_blob, l_file_name, 'application/zip');
        else
            l_blob := apex_util.clob_to_blob(l_content, 'AL32UTF8');
            download(
                l_blob,
                l_file_name,
                case when l_file_name like '%.sql' then 'text/plain; charset=utf-8' else 'application/json; charset=utf-8' end );
        end if;
    end export_download;

    -- stores the export in a collection, so a region can show it as a preview
    procedure export_preview is
        l_content   clob;
        l_file_name varchar2(1000);
        l_blob      blob;
    begin
        apex_collection.create_or_truncate_collection(c_doc);
        if nvl(item('FORMAT'), 'JSON') = 'ZIP' then
            set_item('FORMAT', 'JSON');
            export_content(l_content, l_file_name, l_blob);
            set_item('FORMAT', 'ZIP');
            l_file_name := replace(l_file_name, '.ords.json', '.ords.zip');
        else
            export_content(l_content, l_file_name, l_blob);
        end if;
        apex_collection.add_member(
            p_collection_name => c_doc,
            p_c001            => 'EXPORT',
            p_c002            => l_file_name,
            p_clob001         => l_content );
    end export_preview;

    --------------------------------------------------------------------------------
    -- import
    --------------------------------------------------------------------------------
    procedure plan_row (
        p_kind   in varchar2,
        p_label  in varchar2,
        p_status in varchar2,
        p_module in varchar2 default null,
        p_level  in number   default 0,
        p_info   in varchar2 default null )
    is
    begin
        apex_collection.add_member(
            p_collection_name => c_plan,
            p_c001            => p_kind,
            p_c002            => p_label,
            p_c003            => p_status,
            p_c004            => p_module,
            p_c005            => p_info,
            p_n001            => p_level );
    end plan_row;

    -- compares the document with the schema and records what an import would do
    procedure build_plan (p_doc in json_object_t) is
        l_modules    json_array_t := get_array(p_doc, 'modules');
        l_privileges json_array_t := get_array(p_doc, 'privileges');
        l_roles      json_array_t := get_array(p_doc, 'roles');
        l_module     json_object_t;
        l_existing   json_object_t;
        l_templates  json_array_t;
        l_template   json_object_t;
        l_handlers   json_array_t;
        l_handler    json_object_t;
        l_old_map    t_object_map;
        l_old_hmap   t_object_map;
        l_seen       t_name_set;
        l_seen_h     t_name_set;
        l_name       varchar2(255);
        l_key        varchar2(1000);
        l_id         number;
        l_count      number;
        l_status     varchar2(30);
        l_array      json_array_t;
    begin
        apex_collection.create_or_truncate_collection(c_plan);
        for i in 0 .. l_roles.get_size - 1 loop
            l_name := l_roles.get_string(i);
            select count(*) into l_count from user_ords_roles where name = l_name;
            plan_row('ROLE', l_name, case when l_count = 0 then 'NEW' else 'UNCHANGED' end);
        end loop;
        for i in 0 .. l_privileges.get_size - 1 loop
            l_name := as_object(l_privileges.get(i)).get_string('name');
            select max(id) into l_id from user_ords_privileges where name = l_name;
            plan_row(
                'PRIVILEGE',
                l_name,
                case
                    when l_id is null then 'NEW'
                    when same(privilege_object(l_id), as_object(l_privileges.get(i))) then 'UNCHANGED'
                    else 'CHANGED'
                end );
        end loop;
        for m in 0 .. l_modules.get_size - 1 loop
            l_module := as_object(l_modules.get(m));
            l_name   := l_module.get_string('name');
            l_id     := module_id(l_name);
            l_old_map.delete;
            l_seen.delete;
            if l_id is null then
                l_existing := null;
                l_status   := 'NEW';
            else
                l_existing := module_object(l_id);
                l_array    := get_array(l_existing, 'templates');
                for t in 0 .. l_array.get_size - 1 loop
                    l_old_map(as_object(l_array.get(t)).get_string('uriTemplate')) := as_object(l_array.get(t));
                end loop;
                l_status := case
                                when l_module.has('partial') then 'UNCHANGED'
                                when same(l_existing, l_module, 'templates') then 'UNCHANGED'
                                else 'CHANGED'
                            end;
            end if;
            plan_row(
                'MODULE', l_name, l_status, l_name, 0,
                l_module.get_string('basePath') || case when l_module.has('partial') then ' · partial export' end );
            l_templates := get_array(l_module, 'templates');
            for t in 0 .. l_templates.get_size - 1 loop
                l_template := as_object(l_templates.get(t));
                l_key      := l_template.get_string('uriTemplate');
                l_seen(l_key) := true;
                l_old_hmap.delete;
                l_seen_h.delete;
                if l_old_map.exists(l_key) then
                    l_array := get_array(l_old_map(l_key), 'handlers');
                    for h in 0 .. l_array.get_size - 1 loop
                        l_old_hmap(as_object(l_array.get(h)).get_string('method')) := as_object(l_array.get(h));
                    end loop;
                    l_status := case when same(l_old_map(l_key), l_template, 'handlers') then 'UNCHANGED' else 'CHANGED' end;
                else
                    l_status := 'NEW';
                end if;
                plan_row('TEMPLATE', l_key, l_status, l_name, 1);
                l_handlers := get_array(l_template, 'handlers');
                for h in 0 .. l_handlers.get_size - 1 loop
                    l_handler := as_object(l_handlers.get(h));
                    l_seen_h(l_handler.get_string('method')) := true;
                    plan_row(
                        'HANDLER',
                        l_handler.get_string('method'),
                        case
                            when not l_old_hmap.exists(l_handler.get_string('method')) then 'NEW'
                            when same(l_old_hmap(l_handler.get_string('method')), l_handler) then 'UNCHANGED'
                            else 'CHANGED'
                        end,
                        l_name, 2, l_key );
                end loop;
                l_key := l_old_hmap.first;
                while l_key is not null loop
                    if not l_seen_h.exists(l_key) then
                        plan_row('HANDLER', l_key, 'EXISTING', l_name, 2, l_template.get_string('uriTemplate'));
                    end if;
                    l_key := l_old_hmap.next(l_key);
                end loop;
            end loop;
            l_key := l_old_map.first;
            while l_key is not null loop
                if not l_seen.exists(l_key) then
                    plan_row('TEMPLATE', l_key, 'EXISTING', l_name, 1);
                end if;
                l_key := l_old_map.next(l_key);
            end loop;
        end loop;
    end build_plan;

    -- validates a parsed file and adds its content to the combined document
    procedure add_document (
        p_text       in clob,
        p_source     in varchar2,
        p_modules    in out nocopy t_object_map,
        p_privileges in out nocopy t_object_map,
        p_roles      in out nocopy t_name_set )
    is
        l_doc    json_object_t;
        l_array  json_array_t;
        l_object json_object_t;
        l_key    varchar2(1000);
    begin
        begin
            l_doc := json_object_t.parse(p_text);
        exception
            when others then
                fail(p_source || ' is not a valid JSON document.');
        end;
        if nvl(get_text(l_doc, 'format'), '-') <> c_format then
            fail(p_source || ' is not a RESTaurant export (format "' || c_format || '" expected).');
        elsif nvl(l_doc.get_number('version'), 0) > c_format_version then
            fail(p_source || ' uses format version ' || l_doc.get_number('version') || ', this application supports version ' || c_format_version || '.');
        end if;
        l_array := get_array(l_doc, 'roles');
        for i in 0 .. l_array.get_size - 1 loop
            if l_array.get(i).is_string and l_array.get_string(i) is not null then
                p_roles(l_array.get_string(i)) := true;
            end if;
        end loop;
        l_array := get_array(l_doc, 'privileges');
        for i in 0 .. l_array.get_size - 1 loop
            l_object := norm_privilege(as_object(l_array.get(i)));
            p_privileges(l_object.get_string('name')) := l_object;
        end loop;
        l_array := get_array(l_doc, 'modules');
        for i in 0 .. l_array.get_size - 1 loop
            l_object := norm_module(as_object(l_array.get(i)));
            l_key    := l_object.get_string('name');
            if p_modules.exists(l_key) then
                -- the same module in several files: later parts are added
                if l_object.has('partial') then
                    p_modules(l_key) := with_children(
                                            p_modules(l_key),
                                            'templates',
                                            get_array(merge_module(p_modules(l_key), l_object), 'templates') );
                else
                    p_modules(l_key) := merge_module(p_modules(l_key), l_object);
                end if;
            else
                p_modules(l_key) := l_object;
            end if;
        end loop;
    end add_document;

    -- IMPORT_LOAD: reads the uploaded file (JSON or ZIP) or the pasted text
    procedure import_load is
        l_modules    t_object_map;
        l_privileges t_object_map;
        l_roles      t_name_set;
        l_doc        json_object_t := new_document(false);
        l_array      json_array_t;
        l_key        varchar2(1000);
        l_text       clob := item_clob('TEXT');
        l_files      apex_zip.t_files;
        l_source     varchar2(1000);
        l_count      pls_integer := 0;
        l_found      boolean := false;
        l_file       varchar2(4000) := item('FILE');
    begin
        for f in ( select filename, blob_content
                     from apex_application_temp_files
                    where name = l_file )
        loop
            l_found  := true;
            l_source := f.filename;
            if dbms_lob.getlength(f.blob_content) > 4
               and dbms_lob.substr(f.blob_content, 4, 1) = hextoraw('504B0304')
            then
                l_files := apex_zip.get_files(p_zipped_blob => f.blob_content);
                for i in 1 .. l_files.count loop
                    if lower(l_files(i)) like '%.json' then
                        add_document(
                            apex_util.blob_to_clob(apex_zip.get_file_content(f.blob_content, l_files(i)), 'AL32UTF8'),
                            l_files(i), l_modules, l_privileges, l_roles );
                        l_count := l_count + 1;
                    end if;
                end loop;
                if l_count = 0 then
                    fail('The archive does not contain any .json files.');
                end if;
            else
                add_document(apex_util.blob_to_clob(f.blob_content, 'AL32UTF8'), f.filename, l_modules, l_privileges, l_roles);
            end if;
        end loop;
        if not l_found then
            if l_text is null or dbms_lob.getlength(l_text) = 0 then
                fail('Choose a file or paste an export to import.');
            end if;
            l_source := 'Pasted text';
            add_document(l_text, 'The pasted text', l_modules, l_privileges, l_roles);
        end if;
        l_array := json_array_t();
        l_key   := l_roles.first;
        while l_key is not null loop
            l_array.append(l_key);
            l_key := l_roles.next(l_key);
        end loop;
        l_doc.put('roles', l_array);
        l_array := json_array_t();
        l_key   := l_privileges.first;
        while l_key is not null loop
            l_array.append(l_privileges(l_key));
            l_key := l_privileges.next(l_key);
        end loop;
        l_doc.put('privileges', l_array);
        l_array := json_array_t();
        l_key   := l_modules.first;
        while l_key is not null loop
            l_array.append(l_modules(l_key));
            l_key := l_modules.next(l_key);
        end loop;
        l_doc.put('modules', l_array);
        if l_modules.count + l_privileges.count + l_roles.count = 0 then
            fail('The export does not contain any modules, privileges or roles.');
        end if;
        apex_collection.create_or_truncate_collection(c_doc);
        apex_collection.add_member(
            p_collection_name => c_doc,
            p_c001            => 'IMPORT',
            p_c002            => l_source,
            p_n001            => l_modules.count,
            p_clob001         => l_doc.to_clob );
        build_plan(l_doc);
    end import_load;

    function loaded_document return json_object_t is
        l_text clob;
    begin
        select clob001 into l_text
          from apex_collections
         where collection_name = c_doc
           and c001 = 'IMPORT';
        return json_object_t.parse(l_text);
    exception
        when no_data_found then
            fail('There is no loaded export any more. Please start the import again.');
    end loaded_document;

    -- IMPORT_APPLY
    --   MODE              MERGE | REPLACE | SKIP  (what happens to existing modules)
    --   MODULES           colon separated names of the modules to import
    --   IMPORT_SECURITY   Y = import roles and privileges
    --   STATUS            KEEP | PUBLISHED | NOT_PUBLISHED
    --   NEW_NAME          import a single module under another name
    --   NEW_BASE_PATH     and/or another base path
    procedure import_apply is
        l_doc        json_object_t := loaded_document;
        l_mode       varchar2(30)  := nvl(item('MODE'), 'MERGE');
        l_status     varchar2(30)  := nvl(item('STATUS'), 'KEEP');
        l_new_name   varchar2(255) := trim(item('NEW_NAME'));
        l_new_path   varchar2(255) := norm_base_path(item('NEW_BASE_PATH'));
        l_selected   t_name_set;
        l_names      apex_t_varchar2 := apex_string.split(item('MODULES'), ':');
        l_modules    json_array_t := get_array(l_doc, 'modules');
        l_privileges json_array_t := get_array(l_doc, 'privileges');
        l_roles      json_array_t := get_array(l_doc, 'roles');
        l_module     json_object_t;
        l_name       varchar2(255);
        l_id         number;
        l_done       pls_integer := 0;
        l_skipped    pls_integer := 0;
        l_security   pls_integer := 0;
        l_old_name   varchar2(255);
        l_links      json_array_t;
    begin
        for i in 1 .. l_names.count loop
            if l_names(i) is not null then
                l_selected(l_names(i)) := true;
            end if;
        end loop;
        if ( l_new_name is not null or l_new_path is not null )
           and l_selected.count <> 1
        then
            fail('A new name or base path can only be given when exactly one module is imported.');
        end if;
        if is_yes('IMPORT_SECURITY') then
            for i in 0 .. l_roles.get_size - 1 loop
                ords.create_role(p_role_name => l_roles.get_string(i));
                l_security := l_security + 1;
            end loop;
        end if;
        for m in 0 .. l_modules.get_size - 1 loop
            l_module := as_object(l_modules.get(m));
            l_name   := l_module.get_string('name');
            if l_selected.exists(l_name) then
                if l_new_name is not null then
                    l_old_name := l_name;
                    l_name     := l_new_name;
                    l_module.put('name', l_name);
                end if;
                if l_new_path is not null then
                    l_module.put('basePath', l_new_path);
                end if;
                if l_status in ('PUBLISHED', 'NOT_PUBLISHED') then
                    l_module.put('status', l_status);
                end if;
                l_module := norm_module(l_module);
                l_id     := module_id(l_name);
                if l_id is null then
                    if l_module.has('partial') then
                        l_module.remove('partial');
                    end if;
                    apply_module(l_module);
                    l_done := l_done + 1;
                elsif l_mode = 'SKIP' then
                    l_skipped := l_skipped + 1;
                elsif l_mode = 'REPLACE' and not l_module.has('partial') then
                    apply_module(l_module);
                    l_done := l_done + 1;
                else
                    apply_changes(module_object(l_id), l_module);
                    l_done := l_done + 1;
                end if;
            end if;
        end loop;
        if is_yes('IMPORT_SECURITY') then
            for i in 0 .. l_privileges.get_size - 1 loop
                l_module := as_object(l_privileges.get(i));
                if l_old_name is not null then
                    -- the privilege should protect the module under its new name
                    l_links := json_array_t();
                    for j in 0 .. get_array(l_module, 'modules').get_size - 1 loop
                        l_links.append(
                            case get_array(l_module, 'modules').get_string(j)
                                when l_old_name then l_new_name
                                else get_array(l_module, 'modules').get_string(j)
                            end );
                    end loop;
                    l_module := with_children(l_module, 'modules', l_links);
                end if;
                apply_privilege(l_module);
                l_security := l_security + 1;
            end loop;
        end if;
        apex_collection.create_or_truncate_collection(c_doc);
        apex_collection.create_or_truncate_collection(c_plan);
        g_message :=
            l_done || case when l_done = 1 then ' module' else ' modules' end || ' imported'
            || case when l_skipped > 0 then ', ' || l_skipped || ' skipped' end
            || case when l_security > 0 then ', ' || l_security || ' roles and privileges applied' end
            || '.';
    end import_apply;

    --------------------------------------------------------------------------------
    -- compile check
    --
    -- The source of a handler is parsed by the database, which finds syntax errors
    -- and unknown tables, columns or program units. Nothing is executed: a query
    -- is parsed as an inline view and PL/SQL as a nested block, so a statement of
    -- another kind, for example DDL, is a syntax error and can never run.
    --
    -- PL/SQL with bind variables is only checked for its syntax by the database.
    -- To get the full check, every bind variable :name is replaced by a local
    -- variable ":name" of a fitting type for the duration of the check.
    --------------------------------------------------------------------------------
    procedure line_of (p_source in clob, p_position in pls_integer, p_line out number, p_column out number) is
        l_length pls_integer := dbms_lob.getlength(p_source);
        l_target pls_integer := greatest(least(p_position, l_length), 1);
        l_start  pls_integer := 1;
        l_next   pls_integer;
    begin
        p_line := 1;
        loop
            l_next := dbms_lob.instr(p_source, c_lf, l_start);
            exit when l_next = 0 or l_next >= l_target;
            p_line  := p_line + 1;
            l_start := l_next + 1;
        end loop;
        p_column := l_target - l_start + 1;
    end line_of;

    function line_text (p_source in clob, p_line in number) return varchar2 is
        l_start pls_integer := 1;
        l_next  pls_integer;
    begin
        for i in 2 .. p_line loop
            l_next := dbms_lob.instr(p_source, c_lf, l_start);
            exit when l_next = 0;
            l_start := l_next + 1;
        end loop;
        l_next := dbms_lob.instr(p_source, c_lf, l_start);
        return dbms_lob.substr(p_source, least(case when l_next = 0 then 4000 else l_next - l_start end, 4000), l_start);
    end line_text;

    -- the declarations of the local variables that stand in for the bind variables
    function bind_declarations (p_source in clob, p_handler_id in number) return varchar2 is
        type t_types is table of varchar2(60) index by varchar2(200);
        l_types  t_types;
        l_done   t_name_set;
        l_result varchar2(32767);
        l_name   varchar2(200);
        l_key    varchar2(200);
        l_n      pls_integer := 1;
    begin
        -- parameters ORDS provides on its own
        l_types('BODY')      := 'blob';
        l_types('BODY_TEXT') := 'clob';
        l_types('BODY_JSON') := 'clob';
        for i in 1 .. 7 loop
            l_types(case i
                        when 1 then 'STATUS_CODE'
                        when 2 then 'FETCH_OFFSET'
                        when 3 then 'FETCH_SIZE'
                        when 4 then 'ROW_OFFSET'
                        when 5 then 'ROW_COUNT'
                        when 6 then 'PAGE_OFFSET'
                        else 'PAGE_SIZE'
                    end) := 'number';
        end loop;
        -- parameters of the handler
        for p in ( select upper(bind_variable_name) bind_name, param_type
                     from user_ords_parameters
                    where handler_id = p_handler_id
                      and bind_variable_name is not null )
        loop
            l_types(p.bind_name) := case
                                        when p.param_type = 'RESULTSET'                then 'sys_refcursor'
                                        when p.param_type in ('INT', 'LONG', 'DOUBLE') then 'number'
                                        when p.param_type = 'BOOLEAN'                  then 'boolean'
                                        when p.param_type = 'TIMESTAMP'                then 'timestamp with time zone'
                                        else 'varchar2(32767)'
                                    end;
        end loop;
        loop
            l_name := regexp_substr(p_source, c_bind, 1, l_n, null, 2);
            exit when l_name is null or l_n > 2000;
            if not l_done.exists(l_name) then
                l_done(l_name) := true;
                l_key    := upper(substr(l_name, 2));
                l_result := l_result || '"' || l_name || '" '
                         || case when l_types.exists(l_key) then l_types(l_key) else 'varchar2(32767)' end || '; ';
            end if;
            l_n := l_n + 1;
        end loop;
        return l_result;
    end bind_declarations;

    -- translates a column of the checked text back to the column of the source:
    -- every replaced bind variable in front of it made the line two characters longer
    function source_column (p_line_text in varchar2, p_column in number) return number is
        l_n      pls_integer := 1;
        l_start  pls_integer;
        l_length pls_integer;
        l_shift  pls_integer := 0;
    begin
        loop
            l_start := regexp_instr(p_line_text, c_bind, 1, l_n, 0, null, 2);
            exit when nvl(l_start, 0) = 0;
            l_length := length(regexp_substr(p_line_text, c_bind, 1, l_n, null, 2));
            exit when l_start + l_shift >= p_column;
            if p_column < l_start + l_shift + l_length + 2 then
                return l_start; -- the error is at the bind variable itself
            end if;
            l_shift := l_shift + 2;
            l_n     := l_n + 1;
        end loop;
        return greatest(p_column - l_shift, 1);
    end source_column;

    -- p_status: OK, ERROR, SKIPPED (not checked) or EMPTY
    procedure check_source (
        p_source      in  clob,
        p_source_type in  varchar2,
        p_handler_id  in  number,
        p_status      out varchar2,
        p_line        out number,
        p_column      out number,
        p_message     out varchar2 )
    is
        l_length    pls_integer := nvl(dbms_lob.getlength(p_source), 0);
        l_plsql     boolean     := p_source_type = 'plsql/block';
        l_prefix    varchar2(32767);
        l_statement clob;
        l_tail      varchar2(800);
        l_cursor    integer;
        l_error     varchar2(32767);
        l_offset    pls_integer;
        l_lines     number;
        l_ignore    number;
    begin
        if l_length = 0 or ( l_length <= 4000 and regexp_like(dbms_lob.substr(p_source, 4000, 1), '^\s*$') ) then
            p_status := 'EMPTY';
            return;
        elsif p_source_type = 'mle/javascript' then
            p_status  := 'SKIPPED';
            p_message := 'JavaScript handlers are not checked.';
            return;
        end if;
        line_of(p_source, l_length, l_lines, l_ignore);
        if l_plsql then
            l_prefix    := 'declare ' || bind_declarations(p_source, p_handler_id) || 'begin ';
            l_statement := l_prefix || regexp_replace(p_source, c_bind, '\1"\2"') || c_lf || 'end;';
        else
            l_tail := dbms_lob.substr(p_source, 200, greatest(l_length - 199, 1));
            if regexp_like(l_tail, ';\s*$') then
                p_status  := 'ERROR';
                p_message := 'A query must not end with a semicolon.';
                line_of(p_source, greatest(l_length - 199, 1) + length(regexp_replace(l_tail, '\s+$')) - 1, p_line, p_column);
                return;
            end if;
            l_prefix    := 'select 1 from (';
            l_statement := l_prefix || p_source || c_lf || ')';
        end if;
        l_cursor := dbms_sql.open_cursor;
        begin
            dbms_sql.parse(l_cursor, l_statement, dbms_sql.native);
            p_status := 'OK';
        exception
            when others then
                l_error  := sqlerrm;
                l_offset := dbms_sql.last_error_position;
                p_status := 'ERROR';
                if l_plsql and l_error like 'ORA-06550%' then
                    -- ORA-06550: line 3, column 9: followed by the actual message
                    p_line    := to_number(regexp_substr(l_error, 'line (\d+), column (\d+)', 1, 1, null, 1));
                    p_column  := to_number(regexp_substr(l_error, 'line (\d+), column (\d+)', 1, 1, null, 2));
                    p_message := regexp_substr(l_error, ':' || c_lf || '(.*?)(' || c_lf || 'ORA-06550|$)', 1, 1, 'n', 1);
                    p_message := substr(trim(regexp_replace(regexp_replace(p_message, '\s+', ' '), '^PL/SQL: ')), 1, 500);
                    if p_message like 'PLS-00456%' then
                        p_message := p_message || '. Add a parameter of the data type RESULTSET for this bind variable.';
                    end if;
                    if p_line = 1 then
                        p_column := p_column - length(l_prefix);
                    end if;
                    if p_line <= l_lines then
                        p_column := source_column(line_text(p_source, p_line), p_column);
                    end if;
                elsif l_plsql then
                    p_message := regexp_substr(l_error, '^[^' || c_lf || ']*');
                else
                    line_of(p_source, l_offset - length(l_prefix) + 1, p_line, p_column);
                    p_message := regexp_substr(l_error, '^[^' || c_lf || ']*');
                end if;
                if nvl(p_line, l_lines + 1) > l_lines then
                    -- the error is at the end of the source
                    line_of(p_source, l_length, p_line, p_column);
                end if;
                p_column  := greatest(nvl(p_column, 1), 1);
                p_message := nvl(p_message, regexp_substr(l_error, '^[^' || c_lf || ']*'));
        end;
        if dbms_sql.is_open(l_cursor) then
            dbms_sql.close_cursor(l_cursor);
        end if;
    end check_source;

    -- HANDLER_CHECK: checks SOURCE of the type SOURCE_TYPE as it is entered on the
    -- page, saved or not, and returns CHECK_STATUS, CHECK_LINE, CHECK_COLUMN and
    -- CHECK_MESSAGE. ID is the handler, its parameters give the bind variables
    -- their types.
    procedure handler_check is
        l_status  varchar2(30);
        l_line    number;
        l_column  number;
        l_message varchar2(32767);
    begin
        check_source(item_clob('SOURCE'), item('SOURCE_TYPE'), to_number(item('ID')), l_status, l_line, l_column, l_message);
        set_item('CHECK_STATUS', l_status);
        set_item('CHECK_LINE', l_line);
        set_item('CHECK_COLUMN', l_column);
        set_item('CHECK_MESSAGE', substr(l_message, 1, 4000));
    end handler_check;

    -- HANDLERS_CHECK: checks the saved handlers of the module ID, or of all modules
    -- when ID is empty, and stores one row per handler in a collection
    procedure handlers_check is
        l_module_id number := to_number(item('ID'));
        l_status    varchar2(30);
        l_line      number;
        l_column    number;
        l_message   varchar2(32767);
    begin
        apex_collection.create_or_truncate_collection(c_check);
        for h in ( select h.id, h.method, h.source_type, h.source, t.uri_template, m.name, m.uri_prefix
                     from user_ords_handlers h
                     join user_ords_templates t on t.id = h.template_id
                     join user_ords_modules m on m.id = t.module_id
                    where l_module_id is null or m.id = l_module_id
                    order by m.name, t.uri_template, h.method )
        loop
            check_source(h.source, h.source_type, h.id, l_status, l_line, l_column, l_message);
            apex_collection.add_member(
                p_collection_name => c_check,
                p_c001            => l_status,
                p_c002            => h.method,
                p_c003            => h.uri_prefix || h.uri_template,
                p_c004            => h.name,
                p_c005            => substr(l_message, 1, 4000),
                p_n001            => h.id,
                p_n002            => l_line,
                p_n003            => l_column );
        end loop;
    end handlers_check;

    --------------------------------------------------------------------------------
    -- editing
    --------------------------------------------------------------------------------
    procedure module_save is
        l_id        number        := to_number(item('ID'));
        l_name      varchar2(255) := trim(item('NAME'));
        l_base_path varchar2(255) := norm_base_path(item('BASE_PATH'));
        l_ipp       number        := nvl(item_number('ITEMS_PER_PAGE', 'Pagination size'), 25);
        l_status    varchar2(30)  := nvl(item('STATUS'), 'PUBLISHED');
        l_origins   varchar2(4000) := trim(item('ORIGINS_ALLOWED'));
        l_comments  varchar2(4000) := item('COMMENTS');
        l_privilege varchar2(255) := item('PRIVILEGE');
        l_module    json_object_t;
        l_count     number;
        l_old_privilege varchar2(255);
    begin
        if l_name is null then
            fail('Enter a module name.');
        elsif l_base_path is null then
            fail('Enter a base path.');
        end if;
        select count(*) into l_count from user_ords_modules
         where name = l_name and ( l_id is null or id <> l_id );
        if l_count > 0 then
            fail('A module named "' || l_name || '" already exists.');
        end if;
        select count(*) into l_count from user_ords_modules
         where uri_prefix = l_base_path and ( l_id is null or id <> l_id );
        if l_count > 0 then
            fail('The base path "' || l_base_path || '" is already used by another module.');
        end if;
        if l_id is null then
            l_module := json_object_t();
        else
            l_module := module_object(l_id);
            if l_module.get_string('name') <> l_name or l_module.get_string('basePath') <> l_base_path then
                ords.rename_module(
                    p_module_name   => l_module.get_string('name'),
                    p_new_name      => l_name,
                    p_new_base_path => l_base_path );
            end if;
        end if;
        if l_id is null
           or l_module.get_number('itemsPerPage') <> l_ipp
           or nvl(l_module.get_string('comments'), chr(0)) <> nvl(l_comments, chr(0))
        then
            -- these attributes can only be set by defining the module again
            l_module.put('name', l_name);
            l_module.put('basePath', l_base_path);
            l_module.put('itemsPerPage', l_ipp);
            l_module.put('status', l_status);
            l_module.put('originsAllowed', l_origins);
            l_module.put('comments', l_comments);
            apply_module(norm_module(l_module));
        else
            if l_module.get_string('status') <> l_status then
                ords.publish_module(p_module_name => l_name, p_status => l_status);
            end if;
            if nvl(l_module.get_string('originsAllowed'), chr(0)) <> nvl(l_origins, chr(0)) then
                ords.set_module_origins_allowed(p_module_name => l_name, p_origins_allowed => l_origins);
            end if;
        end if;
        select max(privilege_name) into l_old_privilege from user_ords_privilege_modules where module_name = l_name;
        if nvl(l_old_privilege, chr(0)) <> nvl(l_privilege, chr(0)) then
            ords.set_module_privilege(p_module_name => l_name, p_privilege_name => l_privilege);
        end if;
        set_item('ID', module_id(l_name));
    end module_save;

    procedure module_delete is
        l_id number := to_number(item('ID'));
    begin
        for m in ( select name from user_ords_modules where id = l_id ) loop
            ords.delete_module(p_module_name => m.name);
        end loop;
    end module_delete;

    -- MODULE_COPY: ID = source module, NEW_NAME, NEW_BASE_PATH
    procedure module_copy is
        l_module    json_object_t := module_object(to_number(item('ID')));
        l_name      varchar2(255) := trim(item('NEW_NAME'));
        l_base_path varchar2(255) := norm_base_path(item('NEW_BASE_PATH'));
        l_count     number;
    begin
        if l_name is null or l_base_path is null then
            fail('Enter a name and a base path for the copy.');
        end if;
        select count(*) into l_count from user_ords_modules where name = l_name or uri_prefix = l_base_path;
        if l_count > 0 then
            fail('A module with this name or base path already exists.');
        end if;
        l_module.put('name', l_name);
        l_module.put('basePath', l_base_path);
        if item('NEW_STATUS') in ('PUBLISHED', 'NOT_PUBLISHED') then
            l_module.put('status', item('NEW_STATUS'));
        end if;
        apply_module(norm_module(l_module));
        set_item('NEW_ID', module_id(l_name));
    end module_copy;

    procedure template_save is
        l_id         number         := to_number(item('ID'));
        l_module_id  number         := to_number(item('MODULE_ID'));
        l_pattern    varchar2(600)  := trim(item('URI_TEMPLATE'));
        l_template   json_object_t;
        l_module     varchar2(255);
        l_old        varchar2(600);
        l_count      number;
    begin
        if l_id is not null then
            select module_id, uri_template into l_module_id, l_old from user_ords_templates where id = l_id;
        end if;
        select name into l_module from user_ords_modules where id = l_module_id;
        if l_pattern is null then
            fail('Enter a URI template.');
        end if;
        select count(*) into l_count from user_ords_templates
         where module_id = l_module_id and uri_template = l_pattern and ( l_id is null or id <> l_id );
        if l_count > 0 then
            fail('The module already has a template "' || l_pattern || '".');
        end if;
        l_template := case when l_id is null then json_object_t() else template_object(l_id) end;
        l_template.put('uriTemplate', l_pattern);
        l_template.put('priority', nvl(item_number('PRIORITY', 'Priority'), 0));
        l_template.put('etagType', nvl(item('ETAG_TYPE'), 'HASH'));
        l_template.put('etagQuery', item('ETAG_QUERY'));
        l_template.put('comments', item('COMMENTS'));
        l_template := norm_template(l_template, 'Module "' || l_module || '"');
        if l_old <> l_pattern then
            ords.delete_template(p_module_name => l_module, p_uri_template => l_old);
        end if;
        apply_template(l_module, l_template);
        select id into l_id from user_ords_templates where module_id = l_module_id and uri_template = l_pattern;
        set_item('ID', l_id);
    exception
        when no_data_found then
            fail('The template or its module does not exist any more.');
    end template_save;

    procedure template_delete is
        l_id number := to_number(item('ID'));
    begin
        for t in ( select m.name, t.uri_template
                     from user_ords_templates t
                     join user_ords_modules m on m.id = t.module_id
                    where t.id = l_id )
        loop
            ords.delete_template(p_module_name => t.name, p_uri_template => t.uri_template);
        end loop;
    end template_delete;

    procedure handler_context (
        p_handler_id  in number,
        p_template_id in out number,
        p_module      out varchar2,
        p_pattern     out varchar2,
        p_method      out varchar2 )
    is
    begin
        if p_handler_id is not null then
            select template_id, method into p_template_id, p_method from user_ords_handlers where id = p_handler_id;
        end if;
        select m.name, t.uri_template into p_module, p_pattern
          from user_ords_templates t
          join user_ords_modules m on m.id = t.module_id
         where t.id = p_template_id;
    exception
        when no_data_found then
            fail('The handler or its template does not exist any more.');
    end handler_context;

    procedure handler_save is
        l_id          number := to_number(item('ID'));
        l_template_id number := to_number(item('TEMPLATE_ID'));
        l_method      varchar2(10) := upper(item('METHOD'));
        l_handler     json_object_t;
        l_module      varchar2(255);
        l_pattern     varchar2(600);
        l_old         varchar2(10);
        l_count       number;
    begin
        handler_context(l_id, l_template_id, l_module, l_pattern, l_old);
        select count(*) into l_count from user_ords_handlers
         where template_id = l_template_id and method = l_method and ( l_id is null or id <> l_id );
        if l_count > 0 then
            fail('The template already has a ' || l_method || ' handler.');
        end if;
        l_handler := case when l_id is null then json_object_t() else handler_object(l_id) end;
        l_handler.put('method', l_method);
        l_handler.put('sourceType', item('SOURCE_TYPE'));
        if trim(item('ITEMS_PER_PAGE')) is null then
            l_handler.put_null('itemsPerPage');
        else
            l_handler.put('itemsPerPage', item_number('ITEMS_PER_PAGE', 'Pagination size'));
        end if;
        l_handler.put('mimesAllowed', trim(item('MIMES_ALLOWED')));
        l_handler.put('mleEnvironment', trim(item('MLE_ENV_NAME')));
        l_handler.put('comments', item('COMMENTS'));
        l_handler.put('source', item_clob('SOURCE'));
        l_handler := norm_handler(l_handler, 'Template "' || l_pattern || '"');
        if get_array(l_handler, 'source').get_size = 0 and not l_handler.get('source').is_string then
            fail('Enter the source of the handler.');
        end if;
        if l_old <> l_method then
            ords.delete_handler(p_module_name => l_module, p_uri_template => l_pattern, p_method => l_old);
        end if;
        apply_handler(l_module, l_pattern, l_handler);
        select id into l_id from user_ords_handlers where template_id = l_template_id and method = l_method;
        set_item('ID', l_id);
    end handler_save;

    procedure handler_delete is
        l_id number := to_number(item('ID'));
    begin
        for h in ( select m.name, t.uri_template, h.method
                     from user_ords_handlers h
                     join user_ords_templates t on t.id = h.template_id
                     join user_ords_modules m on m.id = t.module_id
                    where h.id = l_id )
        loop
            ords.delete_handler(p_module_name => h.name, p_uri_template => h.uri_template, p_method => h.method);
        end loop;
    end handler_delete;

    -- parameters cannot be removed one by one, so the handler is defined again
    -- with the changed list of parameters
    procedure parameter_change (p_delete in boolean) is
        l_id          number := to_number(item('ID'));
        l_handler_id  number := to_number(item('HANDLER_ID'));
        l_template_id number;
        l_name        varchar2(100) := trim(item('NAME'));
        l_old_name    varchar2(100);
        l_module      varchar2(255);
        l_pattern     varchar2(600);
        l_method      varchar2(10);
        l_handler     json_object_t;
        l_params      json_array_t;
        l_result      json_array_t := json_array_t();
        l_param       json_object_t;
        l_current     varchar2(100);
    begin
        if l_id is not null then
            begin
                select handler_id, name into l_handler_id, l_old_name from user_ords_parameters where id = l_id;
            exception
                when no_data_found then
                    fail('The parameter does not exist any more.');
            end;
        end if;
        handler_context(l_handler_id, l_template_id, l_module, l_pattern, l_method);
        if not p_delete and l_name is null then
            fail('Enter a parameter name.');
        end if;
        l_handler := handler_object(l_handler_id);
        l_params  := get_array(l_handler, 'parameters');
        for i in 0 .. l_params.get_size - 1 loop
            l_current := as_object(l_params.get(i)).get_string('name');
            if l_current = l_old_name then
                null; -- replaced or removed
            elsif not p_delete and l_current = l_name then
                fail('The handler already has a parameter "' || l_name || '".');
            else
                l_result.append(l_params.get(i));
            end if;
        end loop;
        if not p_delete then
            l_param := json_object_t();
            l_param.put('name', l_name);
            l_param.put('bindVariable', trim(item('BIND_VARIABLE_NAME')));
            l_param.put('sourceType', item('SOURCE_TYPE'));
            l_param.put('paramType', item('PARAM_TYPE'));
            l_param.put('accessMethod', item('ACCESS_METHOD'));
            l_param.put('comments', item('COMMENTS'));
            l_result.append(l_param);
        end if;
        apply_handler(
            l_module, l_pattern,
            norm_handler(with_children(l_handler, 'parameters', l_result), 'Template "' || l_pattern || '"') );
    end parameter_change;

    --------------------------------------------------------------------------------
    -- entry point
    --------------------------------------------------------------------------------
    procedure run (p_action in varchar2, p_prefix in varchar2) is
        l_action varchar2(30) := upper(p_action);
        l_text   varchar2(32767);
    begin
        g_prefix := nvl(p_prefix, 'P' || apex_application.g_flow_step_id || '_');
        savepoint restaurant_engine;
        case l_action
            when 'MODULE_SAVE'      then module_save;
            when 'MODULE_DELETE'    then module_delete;
            when 'MODULE_COPY'      then module_copy;
            when 'TEMPLATE_SAVE'    then template_save;
            when 'TEMPLATE_DELETE'  then template_delete;
            when 'HANDLER_SAVE'     then handler_save;
            when 'HANDLER_DELETE'   then handler_delete;
            when 'PARAMETER_SAVE'   then parameter_change(p_delete => false);
            when 'PARAMETER_DELETE' then parameter_change(p_delete => true);
            when 'EXPORT_DOWNLOAD'  then export_download;
            when 'EXPORT_PREVIEW'   then export_preview;
            when 'IMPORT_LOAD'      then import_load;
            when 'IMPORT_APPLY'     then import_apply;
            when 'HANDLER_CHECK'    then handler_check;
            when 'HANDLERS_CHECK'   then handlers_check;
            else fail('Unknown engine action "' || l_action || '".');
        end case;
    exception
        when apex_application.e_stop_apex_engine then
            raise;
        when others then
            l_text := sqlerrm;
            rollback to restaurant_engine;
            -- show the first line of the message without the error number
            l_text := regexp_replace(regexp_substr(l_text, '^[^' || c_lf || ']*'), '^ORA-[0-9]+: ');
            -- the message can contain names the user entered, so it is escaped
            apex_error.add_error(
                p_message          => apex_escape.html(substr(l_text, 1, 4000)),
                p_display_location => apex_error.c_inline_in_notification );
    end run;
begin
    run(:action, :prefix);
    :message := g_message;
end;
