// End-to-end walkthrough of RESTaurant.
//
// Plays through the application the way a user would, in a schema that starts
// without any REST definitions: sign in, enable the schema, build a service,
// call it, protect it, export it, import it elsewhere, break and repair it,
// and finally remove everything. Every step checks what the user would see and,
// where it matters, what ORDS answers over HTTP.
//
// Start it with tests/e2e/run.sh, which prepares the sandbox first.
import { chromium } from 'playwright';
import fs from 'node:fs';
import path from 'node:path';
import { cfg, check, equal, contains, run, summary, sql, sqlFile, rest, eventually, App } from './lib.mjs';

const A = 'e2e';      // schema alias of E2E_REST
const B = 'e2e_b';    // schema alias of E2E_REST_B

const browser = await chromium.launch();
const context = await browser.newContext({
  viewport: { width: 1440, height: 1000 },
  acceptDownloads: true,
  permissions: ['clipboard-read', 'clipboard-write']
});
const page = await context.newPage();
const pageErrors = [];
let unloadPrompts = 0;
page.on('pageerror', e => pageErrors.push(e.message));
page.on('dialog', async d => { if (d.type() === 'beforeunload') { unloadPrompts += 1; } await d.accept(); });

const app = new App(page, 'restaurant');
const clipboard = () => page.evaluate(() => navigator.clipboard.readText());
const title = () => page.locator('.t-HeroRegion-title').first().innerText();
const frameOf = async (name) => (await page.locator(`iframe[title="${name}"]`).elementHandle()).contentFrame();
const timed = async (fn) => { const t = Date.now(); await fn(); return Date.now() - t; };
const status = (alias, servicePath, options) => async () => (await rest(alias, 'GET', servicePath, options)).status;

// opens a module, template or handler through the lists, the way a user would
async function openModule(name) {
  await app.go('modules');
  await app.nav(page.locator('#rst-modules a.rst-strong').filter({ hasText: new RegExp('^' + name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '$') }));
}
async function openTemplate(module, template) {
  await openModule(module);
  await app.nav(page.locator('.rst-table a.rst-path').filter({ hasText: new RegExp('^' + template.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '$') }));
}
async function openHandler(module, template, method) {
  await openTemplate(module, template);
  await app.nav(`.rst-table a.rst-method--${method.toLowerCase()}`);
  await app.editor();
}
async function createHandler(module, template, { method, type, source, itemsPerPage, mimes }) {
  await openTemplate(module, template);
  await app.nav(app.button('Create Handler'));
  if (method) { await page.selectOption('#P13_METHOD', method); }
  if (type) { await page.selectOption('#P13_SOURCE_TYPE', type); }
  if (itemsPerPage) { await page.fill('#P13_ITEMS_PER_PAGE', String(itemsPerPage)); }
  if (mimes) { await page.fill('#P13_MIMES_ALLOWED', mimes); }
  await app.setSource(source);
  await app.nav(app.button('Create Handler'));
  await app.editor();
}
async function addParameter({ name, bind, source, access, type }) {
  await app.button('Add Parameter').click();
  const d = app.dialog('Handler Parameter');
  await d.locator('#P14_NAME').fill(name);
  await d.locator('#P14_BIND_VARIABLE_NAME').fill(bind);
  await d.locator('#P14_SOURCE_TYPE').selectOption(source);
  await d.locator('#P14_ACCESS_METHOD').selectOption(access);
  await d.locator('#P14_PARAM_TYPE').selectOption(type);
  await d.getByRole('button', { name: 'Save', exact: true }).click();
  await app.dialogClosed('Handler Parameter');
  await page.waitForTimeout(600);
}
async function importFile(file) {
  await app.go('import');
  await page.setInputFiles('input[type=file]', file);
  await app.nav(app.button('Continue'));
}
async function importText(text) {
  await app.go('import');
  await page.evaluate(t => { document.getElementById('P70_TEXT').value = t; }, text);
}
const planSummary = async () => (await page.locator('.rst-toolbar').first().innerText()).replace(/\s+/g, ' ').trim();
const planRows = () => app.rows('.rst-table tbody tr');
const handlerTimes = (module) => Object.fromEntries(sql('e2e_rest', `
  select h.method || ' ' || t.uri_template || '=' || to_char(h.updated_on, 'HH24:MI:SS')
    from user_ords_handlers h
    join user_ords_templates t on t.id = h.template_id
    join user_ords_modules m on m.id = t.module_id
   where m.name = '${module}';`).map(l => l.split('=')));

const SOURCE = {
  list: 'select product_id, name, price\n  from products\n order by product_id',
  item: 'select product_id, name, price, created_on\n  from products\n where product_id = :id',
  post: 'begin\n    insert into products (name, price)\n    values (:name, :price)\n    returning product_id into :id;\n\n    :status := 201;\nend;',
  put: 'begin\n    update products\n       set name  = nvl(:name, name),\n           price = nvl(:price, price)\n     where product_id = :id;\n\n    :status := case when sql%rowcount = 0 then 404 else 200 end;\nend;',
  del: 'begin\n    delete from products where product_id = :id;\n    :status := case when sql%rowcount = 0 then 404 else 204 end;\nend;'
};

// =====================================================================================
await run('1  Sign in', async () => {
  await page.goto(app.url + 'home');
  contains('the login page shows the application name', await page.title(), 'RESTaurant');
  await page.fill('#P9999_USERNAME', 'NOBODY');
  await page.fill('#P9999_PASSWORD', 'wrong');
  await page.getByRole('button', { name: 'Sign In' }).click();
  await page.waitForLoadState('networkidle');
  check('a wrong login is rejected', await page.locator('#P9999_USERNAME').count() === 1);
  await app.login();
  equal('the right login opens the dashboard', await page.title(), 'Dashboard');
}, page);

await run('2  A schema without REST definitions', async () => {
  check('the dashboard warns that the schema is not REST enabled', await page.locator('.t-Alert--warning').count() === 1);
  equal('all counters are zero', (await page.locator('.rst-stat-value').allInnerTexts()).join(','), '0,0,0,0,0,0,0');
  for (const [pagePath, expected] of [['modules', 'Modules'], ['search', 'Search Source'], ['privileges', 'Privileges'], ['roles', 'Roles'],
    ['oauth-clients', 'OAuth Clients'], ['autorest', 'AutoREST Objects'], ['export', 'Export'], ['import', 'Import'], ['schema', 'Schema Settings']]) {
    await app.go(pagePath);
    const broken = await page.locator('.t-Alert--danger, #apex_error_page').count() + (await page.locator('body').innerText()).includes('Error during rendering');
    check(`page ${expected} opens without an error`, (await page.title()) === expected && !broken, await page.title());
  }
  await app.go('modules');
  contains('the module list explains that it is empty', await page.locator('.rst-empty').innerText(), 'no resource modules');
  await page.getByRole('link', { name: 'About' }).or(page.getByRole('button', { name: 'About' })).first().click();
  const about = app.dialog('About RESTaurant');
  check('the about dialog shows the version', /RESTaurant \d+\.\d+\.\d+/.test(await about.locator('.rst-about').innerText()));
  await page.locator('.ui-dialog-titlebar-close').click();
  await app.nav(app.button('Create Module'));
  await page.fill('#P11_NAME', 'early.v1');
  await page.fill('#P11_BASE_PATH', 'early');
  contains('a module cannot be created before the schema is enabled', await app.error(app.button('Create Module')), 'not REST enabled');
}, page);

await run('3  Schema settings', async () => {
  await app.go('schema');
  equal('the alias defaults to the schema name', await page.inputValue('#P80_PATTERN'), 'e2e_rest');
  await app.set('P80_ENABLED', 'Y');
  await page.fill('#P80_PATTERN', A);
  await app.nav(app.button('Save'));
  equal('the settings are saved', await app.success(), 'Schema settings saved.');
  equal('the service URL uses the alias', await page.locator('#rst-base-url').innerText(), `${cfg.ords}/${A}/`);
  equal('ORDS answers under the alias', (await rest(A, 'GET', '/open-api-catalog/')).status, 200);
  await app.go('home');
  check('the dashboard warning is gone', await page.locator('.t-Alert--warning').count() === 0);
}, page);

await run('4  Modules', async () => {
  await app.go('modules');
  await app.nav(app.button('Create Module'));
  equal('a new module form is empty', await page.inputValue('#P11_NAME'), '');
  contains('the module name is required', await app.error(app.button('Create Module')), 'must have some value');
  await page.fill('#P11_NAME', 'shop.v1');
  await page.fill('#P11_BASE_PATH', 'shop/v1');
  await app.nav(app.button('Create Module'));
  equal('the module is created', await app.success(), 'Module saved.');
  equal('the page shows the module', await title(), 'shop.v1');
  equal('the base path gets its slashes', await page.inputValue('#P11_BASE_PATH'), '/shop/v1/');
  equal('the pagination size defaults to 25', await page.inputValue('#P11_ITEMS_PER_PAGE'), '25');
  equal('a new module is published', await app.value('P11_STATUS'), 'PUBLISHED');
  equal('the endpoint is shown', await page.locator('#rst-module-url').innerText(), `${cfg.ords}/${A}/shop/v1/`);
  await page.locator('.rst-url .rst-copy').click();
  equal('the copy button copies the endpoint', await clipboard(), `${cfg.ords}/${A}/shop/v1/`);

  await app.go('modules');
  await app.nav(app.button('Create Module'));
  await page.fill('#P11_NAME', 'temp.v1');
  await page.fill('#P11_BASE_PATH', '/temp/v1/');
  await app.nav(app.button('Create Module'));
  await page.fill('#P11_NAME', 'shop.v1');
  contains('a module name must be unique', await app.error(app.button('Save')), 'already exists');
  await page.fill('#P11_NAME', 'temp.v1');
  await page.fill('#P11_BASE_PATH', '/shop/v1/');
  contains('a base path must be unique', await app.error(app.button('Save')), 'already used');
  await page.fill('#P11_BASE_PATH', '/temp/v1/');
  await page.fill('#P11_ITEMS_PER_PAGE', 'abc');
  check('the pagination size must be a number', /number|numeric/i.test(await app.error(app.button('Save'))));
  await app.button('Delete').click();
  await Promise.all([page.waitForNavigation(), app.confirm()]);
  await page.waitForLoadState('networkidle');
  equal('deleting a module leads back to the list', await page.title(), 'Modules');
  equal('the deletion is confirmed', await app.success(), 'Module deleted.');
  const rows = await app.rows('#rst-modules tbody tr');
  equal('only the first module is left', rows.length, 1);
  check('the list shows name, path, status and protection', ['shop.v1', '/shop/v1/', 'Published', 'Public'].every(t => rows[0].includes(t)), rows[0]);
  await page.fill('.rst-filter', 'zzz');
  equal('the list filter hides rows', await page.locator('#rst-modules tbody tr:visible').count(), 0);
  await page.fill('.rst-filter', 'shop');
  equal('the list filter finds rows', await page.locator('#rst-modules tbody tr:visible').count(), 1);
}, page);

await run('5  Templates', async () => {
  await openModule('shop.v1');
  contains('a module without templates says so', await page.locator('.rst-empty').innerText(), 'no templates');
  await app.nav(app.button('Create Template'));
  contains('the URI template is required', await app.error(app.button('Create Template')), 'must have some value');
  await page.fill('#P12_URI_TEMPLATE', 'products/');
  await app.nav(app.button('Create Template'));
  equal('the template is created', await app.success(), 'Template saved.');
  equal('the page shows the template', await title(), 'products/');
  equal('the template endpoint is shown', await page.locator('#rst-template-url').innerText(), `${cfg.ords}/${A}/shop/v1/products/`);

  await app.nav('.t-HeroRegion a');
  await app.nav(app.button('Create Template'));
  await page.fill('#P12_URI_TEMPLATE', 'products/:id');
  await page.selectOption('#P12_PRIORITY', '3');
  check('the ETag query is hidden for a hash', !(await page.locator('#P12_ETAG_QUERY').isVisible()));
  await page.selectOption('#P12_ETAG_TYPE', 'QUERY');
  check('the ETag query appears for the type Query', await page.locator('#P12_ETAG_QUERY').isVisible());
  contains('the type Query needs an ETag query', await app.error(app.button('Create Template')), 'needs an ETag query');
  await page.selectOption('#P12_ETAG_TYPE', 'HASH');
  await app.nav(app.button('Create Template'));
  equal('the second template is created', await title(), 'products/:id');
  equal('the priority is kept', await page.inputValue('#P12_PRIORITY'), '3');

  await app.nav('.t-HeroRegion a');
  await app.nav(app.button('Create Template'));
  await page.fill('#P12_URI_TEMPLATE', 'products/');
  contains('a template must be unique in its module', await app.error(app.button('Create Template')), 'already has a template');
  await openModule('shop.v1');
  equal('the module lists both templates', (await app.rows('.rst-table tbody tr')).length, 2);
}, page);

await run('6  Handlers and the code editor', async () => {
  // a query handler, typed by hand
  await openTemplate('shop.v1', 'products/');
  contains('a template without handlers says so', await page.locator('.rst-empty').innerText(), 'no handlers');
  await app.nav(app.button('Create Handler'));
  equal('GET is suggested first', await page.inputValue('#P13_METHOD'), 'GET');
  equal('a GET handler starts as a collection query', await page.inputValue('#P13_SOURCE_TYPE'), 'json/collection');
  check('the allowed MIME types are hidden for GET', !(await page.locator('#P13_MIMES_ALLOWED').isVisible()));
  await app.editor();
  equal('the editor highlights SQL', await page.evaluate(() => document.getElementById('P13_SOURCE').rstEditor.editor.getModel().getLanguageId()), 'sql');
  contains('an empty source cannot be saved', await app.error(app.button('Create Handler')), 'has no source');
  await page.locator('.rst-monaco .view-lines').click();
  await page.keyboard.type('select product_id, name, price from products order by product_id', { delay: 5 });
  equal('typing in the editor fills the field', await page.inputValue('#P13_SOURCE'), 'select product_id, name, price from products order by product_id');
  check('keywords are highlighted', await page.evaluate(() => new Set(Array.from(document.querySelectorAll('.rst-monaco .view-line span span')).map(s => s.className)).size) > 1);
  equal('the typed query passes the compile check', (await app.checkAfterChange()).state, 'ok');
  await page.fill('#P13_ITEMS_PER_PAGE', '3');
  await app.nav(app.button('Create Handler'));
  equal('the handler is created', await app.success(), 'Handler saved.');
  equal('the page shows method and template', await title(), 'GET products/');
  let r = await rest(A, 'GET', '/shop/v1/products/');
  equal('ORDS serves the new handler', r.status, 200);
  check('the pagination size of the handler applies', r.json.items.length === 3 && r.json.hasMore === true, JSON.stringify(r.json).slice(0, 120));

  // request console
  await page.locator('.rst-try-send').click();
  await page.locator('.rst-try-result.is-visible').waitFor();
  contains('the console shows the status', await page.locator('.rst-try-code').innerText(), '200');
  contains('the console shows the response', await page.locator('.rst-try-output').innerText(), 'Product 1');
  await page.locator('.rst-try-curl').click();
  equal('the request can be copied as cURL', await clipboard(), `curl -i -X GET '${cfg.ords}/${A}/shop/v1/products/'`);

  // compile check
  await app.editor();
  await app.setSource('select product_id, nope\n  from products');
  let c = await app.checkAfterChange();
  equal('a wrong column is found while typing', c.state, 'error');
  contains('the error names line and column', c.text, 'Line 1, column 20');
  contains('the error carries the message of the database', c.text, 'ORA-00904');
  equal('the error is marked in the editor', await page.evaluate(() => { const a = document.getElementById('P13_SOURCE').rstEditor; return a.monaco.editor.getModelMarkers({ owner: 'restaurant' }).length; }), 1);
  await page.locator('.rst-check').click();
  equal('a click on the error moves the cursor there', JSON.stringify(await page.evaluate(() => document.getElementById('P13_SOURCE').rstEditor.editor.getPosition())), '{"lineNumber":1,"column":20}');
  await app.setSource('select product_id from products;');
  contains('a query must not end with a semicolon', (await app.checkAfterChange()).text, 'must not end with a semicolon');
  await app.setSource('drop table products');
  equal('a statement that is not a query is an error', (await app.checkAfterChange()).state, 'error');
  equal('and it was not executed', sql('e2e_rest', 'select count(*) from products;')[0].trim() >= '7', true);
  const before = unloadPrompts;
  await app.nav('.rst-tree a.rst-node-link >> nth=0');
  check('leaving a changed handler asks first', unloadPrompts > before);

  // single row
  await createHandler('shop.v1', 'products/:id', { type: 'json/item', source: SOURCE.item });
  r = await rest(A, 'GET', '/shop/v1/products/2');
  check('the item handler returns one row', r.status === 200 && r.json.name === 'Product 2', r.text.slice(0, 100));
  equal('an unknown item gives 404', (await rest(A, 'GET', '/shop/v1/products/999')).status, 404);

  // PL/SQL with parameters
  await openTemplate('shop.v1', 'products/');
  await app.nav(app.button('Create Handler'));
  equal('the next free method is suggested', await page.inputValue('#P13_METHOD'), 'POST');
  equal('a POST handler is PL/SQL', await page.inputValue('#P13_SOURCE_TYPE'), 'plsql/block');
  check('query types are not offered for POST', await page.locator('#P13_SOURCE_TYPE option[value="json/collection"]').isDisabled());
  check('the pagination size is hidden for POST', !(await page.locator('#P13_ITEMS_PER_PAGE').isVisible()));
  await page.fill('#P13_MIMES_ALLOWED', 'application/json');
  await app.setSource(SOURCE.post);
  equal('the editor highlights PL/SQL', await page.evaluate(() => document.getElementById('P13_SOURCE').rstEditor.editor.getModel().getLanguageId()), 'plsql');
  await app.nav(app.button('Create Handler'));
  equal('the POST handler is created', await title(), 'POST products/');
  contains('without parameters the handler has none', await page.locator('.rst-empty').first().innerText(), 'No parameters');
  await addParameter({ name: 'id', bind: 'id', source: 'RESPONSE', access: 'OUT', type: 'INT' });
  await addParameter({ name: 'X-ORDS-STATUS-CODE', bind: 'status', source: 'HEADER', access: 'OUT', type: 'INT' });
  let params = await app.rows('.rst-table >> nth=0 >> tbody tr');
  equal('both parameters are listed', params.length, 2);
  check('a parameter row shows its definition', ['id', ':id', 'OUT', 'Response body', 'INT'].every(t => params.find(p => p.startsWith('id ')).includes(t)), params.join(' | '));

  await app.button('Add Parameter').click();
  let d = app.dialog('Handler Parameter');
  await d.locator('#P14_NAME').fill('id');
  await d.locator('#P14_BIND_VARIABLE_NAME').fill('other');
  contains('a parameter name must be unique', await app.error(d.getByRole('button', { name: 'Save', exact: true }), d), 'already has a parameter');
  await d.locator('#P14_NAME').fill('other');
  await d.locator('#P14_BIND_VARIABLE_NAME').fill('id');
  contains('a bind variable can be used once', await app.error(d.getByRole('button', { name: 'Save', exact: true }), d), 'more than one parameter');
  await d.locator('#P14_NAME').fill('');
  contains('a parameter needs a name', await app.error(d.getByRole('button', { name: 'Save', exact: true }), d), 'must have some value');
  await d.getByRole('button', { name: 'Cancel' }).click();
  await app.dialogClosed('Handler Parameter');

  await page.locator('.rst-table a.rst-strong').filter({ hasText: /^id$/ }).click();
  d = app.dialog('Handler Parameter');
  equal('the parameter dialog loads the parameter', await d.locator('#P14_BIND_VARIABLE_NAME').inputValue(), 'id');
  await d.locator('#P14_NAME').fill('identifier');
  await d.locator('#P14_COMMENTS').fill('key of the new product');
  await d.getByRole('button', { name: 'Save', exact: true }).click();
  await app.dialogClosed('Handler Parameter');
  await page.waitForTimeout(600);
  params = await app.rows('.rst-table >> nth=0 >> tbody tr');
  check('a parameter can be renamed and commented', params.some(p => p.startsWith('identifier ') && p.includes('key of the new product')) && params.length === 2, params.join(' | '));
  await page.locator('.rst-table a.rst-strong').filter({ hasText: /^identifier$/ }).click();
  d = app.dialog('Handler Parameter');
  await d.locator('#P14_NAME').fill('id');
  await d.getByRole('button', { name: 'Save', exact: true }).click();
  await app.dialogClosed('Handler Parameter');

  await addParameter({ name: 'X-Temp', bind: 'temp', source: 'HEADER', access: 'IN', type: 'STRING' });
  await page.locator('.rst-table a.rst-strong').filter({ hasText: /^X-Temp$/ }).click();
  d = app.dialog('Handler Parameter');
  await d.getByRole('button', { name: 'Delete' }).click();
  await app.confirm();
  await app.dialogClosed('Handler Parameter');
  await page.waitForTimeout(600);
  equal('a parameter can be deleted', (await app.rows('.rst-table >> nth=0 >> tbody tr')).length, 2);
  equal('the handler with typed bind variables compiles', (await app.checkResult()).state, 'ok');

  r = await rest(A, 'POST', '/shop/v1/products/', { body: { name: 'Created by REST', price: 9.5 } });
  check('POST creates a row and returns its key', r.status === 201 && Number.isInteger(r.json.id), `${r.status} ${r.text.slice(0, 100)}`);
  const created = r.json.id;
  await page.fill('.rst-try-body', '{"name": "From the console", "price": 1}');
  await page.locator('.rst-try-send').click();
  await page.locator('.rst-try-result.is-visible').waitFor();
  contains('the console sends a request body', await page.locator('.rst-try-code').innerText(), '201');

  // PUT and DELETE
  await createHandler('shop.v1', 'products/:id', { method: 'PUT', source: SOURCE.put, mimes: 'application/json' });
  await addParameter({ name: 'X-ORDS-STATUS-CODE', bind: 'status', source: 'HEADER', access: 'OUT', type: 'INT' });
  await createHandler('shop.v1', 'products/:id', { method: 'DELETE', source: SOURCE.del });
  await addParameter({ name: 'X-ORDS-STATUS-CODE', bind: 'status', source: 'HEADER', access: 'OUT', type: 'INT' });
  equal('PUT changes the row', (await rest(A, 'PUT', `/shop/v1/products/${created}`, { body: { price: 11 } })).status, 200);
  equal('the change is visible', (await rest(A, 'GET', `/shop/v1/products/${created}`)).json.price, 11);
  equal('PUT on an unknown row gives 404', (await rest(A, 'PUT', '/shop/v1/products/999', { body: { price: 1 } })).status, 404);
  equal('DELETE removes the row', (await rest(A, 'DELETE', `/shop/v1/products/${created}`)).status, 204);
  equal('the row is gone', (await rest(A, 'GET', `/shop/v1/products/${created}`)).status, 404);
  await openTemplate('shop.v1', 'products/:id');
  equal('the template lists three handlers', (await app.rows('.rst-table tbody tr')).length, 3);

  // change the method of a handler, delete handler and template
  await openModule('shop.v1');
  await app.nav(app.button('Create Template'));
  await page.fill('#P12_URI_TEMPLATE', 'ping');
  await app.nav(app.button('Create Template'));
  await app.nav(app.button('Create Handler'));
  await page.selectOption('#P13_SOURCE_TYPE', 'json/query;type=single');
  await app.setSource('select sysdate now from dual');
  await app.nav(app.button('Create Handler'));
  await page.selectOption('#P13_METHOD', 'POST');
  equal('changing the method to POST switches to PL/SQL', await page.inputValue('#P13_SOURCE_TYPE'), 'plsql/block');
  await app.setSource('begin\n    null;\nend;');
  await app.nav(app.button('Save'));
  equal('the method of a handler can be changed', await title(), 'POST ping');
  equal('the old method is gone', (await rest(A, 'GET', '/shop/v1/ping')).status, 405);
  await app.button('Delete').click();
  await Promise.all([page.waitForNavigation(), app.confirm()]);
  await page.waitForLoadState('networkidle');
  check('deleting a handler leads back to its template', (await page.title()) === 'Template' && (await app.success()) === 'Handler deleted.');
  await app.button('Delete').click();
  await Promise.all([page.waitForNavigation(), app.confirm()]);
  await page.waitForLoadState('networkidle');
  check('deleting a template leads back to its module', (await page.title()) === 'Module' && (await app.success()) === 'Template deleted.');
  equal('the module has its two templates again', (await app.rows('.rst-table tbody tr')).length, 2);

  // a large source
  await openHandler('shop.v1', 'products/', 'GET');
  const large = SOURCE.list + '\n' + Array.from({ length: 700 }, (_, i) => `-- filler line ${i} ${'x'.repeat(50)}`).join('\n');
  await app.setSource(large);
  await app.nav(app.button('Save'));
  await app.editor();
  equal(`a source of ${large.length} characters is saved completely`, (await page.inputValue('#P13_SOURCE')).length, large.length);
  equal('and still works', (await rest(A, 'GET', '/shop/v1/products/')).status, 200);
  await app.setSource(SOURCE.list);
  await app.nav(app.button('Save'));
}, page);

await run('7  Changing a module that has content', async () => {
  const treeCount = () => page.locator('.rst-tree .rst-node--module.is-current .rst-method').count();
  await openModule('shop.v1');
  await page.fill('#P11_COMMENTS', 'Product catalogue');
  await page.fill('#P11_ITEMS_PER_PAGE', '10');
  await page.fill('#P11_ORIGINS_ALLOWED', 'https://example.com');
  await app.nav(app.button('Save'));
  equal('comments, pagination and origins are saved', [await page.inputValue('#P11_COMMENTS'), await page.inputValue('#P11_ITEMS_PER_PAGE'), await page.inputValue('#P11_ORIGINS_ALLOWED')].join('|'), 'Product catalogue|10|https://example.com');
  equal('the templates survive the change', (await app.rows('.rst-table tbody tr')).length, 2);
  equal('the handlers survive the change', await treeCount(), 5);
  equal('the parameters survive the change', sql('e2e_rest', 'select count(*) from user_ords_parameters;')[0].trim(), '4');
  const waited = await timed(async () => { await eventually(status(A, '/shop/v1/products/1'), 200); });
  equal(`the services answer again after the change (${waited} ms)`, (await rest(A, 'GET', '/shop/v1/products/1')).status, 200);
  await page.fill('#P11_ORIGINS_ALLOWED', '');
  await app.set('P11_STATUS', 'NOT_PUBLISHED');
  await app.nav(app.button('Save'));
  equal('an unpublished module cannot be called', await eventually(status(A, '/shop/v1/products/'), 404), 404);
  check('the tree marks the unpublished module', await page.locator('.rst-tree .rst-dot').count() === 1);
  await app.set('P11_STATUS', 'PUBLISHED');
  await app.nav(app.button('Save'));
  equal('a published module can be called again', await eventually(status(A, '/shop/v1/products/'), 200), 200);

  await page.fill('#P11_NAME', 'store.v1');
  await page.fill('#P11_BASE_PATH', '/store/v1/');
  await app.nav(app.button('Save'));
  equal('the module is renamed', await title(), 'store.v1');
  equal('the old path is gone', await eventually(status(A, '/shop/v1/products/'), 404), 404);
  equal('the new path answers', await eventually(status(A, '/store/v1/products/'), 200), 200);
  equal('renaming keeps the handlers', await treeCount(), 5);
  await page.fill('#P11_NAME', 'shop.v1');
  await page.fill('#P11_BASE_PATH', '/shop/v1/');
  await app.nav(app.button('Save'));

  await app.button('Duplicate').click();
  const d = app.dialog('Duplicate Module');
  equal('a name is suggested for the copy', await d.locator('#P15_NEW_NAME').inputValue(), 'shop.v1.copy');
  equal('a base path is suggested for the copy', await d.locator('#P15_NEW_BASE_PATH').inputValue(), '/shop/v1-copy/');
  await Promise.all([page.waitForNavigation(), d.getByRole('button', { name: 'Duplicate', exact: true }).click()]);
  await page.waitForLoadState('networkidle');
  equal('the copy is opened', await title(), 'shop.v1.copy');
  equal('the copy is not published', await app.value('P11_STATUS'), 'NOT_PUBLISHED');
  equal('the copy has all handlers', await treeCount(), 5);
  equal('the copy has all parameters', sql('e2e_rest', 'select count(*) from user_ords_parameters;')[0].trim(), '8');
}, page);

await run('8  Roles', async () => {
  await app.go('roles');
  const builtIn = (await app.rows('#rst-roles tbody tr')).find(r => r.startsWith('SQL Developer'));
  check('built-in roles are listed as such', builtIn && builtIn.includes('Built-in'), builtIn);
  equal('built-in roles cannot be opened', await page.locator('#rst-roles a').filter({ hasText: 'SQL Developer' }).count(), 0);
  const save = async (name) => {
    const d = app.dialog('Role');
    await d.locator('#P31_NAME').fill(name);
    await d.getByRole('button', { name: 'Save', exact: true }).click();
  };
  await app.button('Create Role').click();
  await save('shop_manager');
  await app.dialogClosed('Role');
  await page.waitForTimeout(500);
  check('a role is created', (await app.rows('#rst-roles tbody tr')).some(r => r.startsWith('shop_manager Custom')));
  await app.button('Create Role').click();
  let d = app.dialog('Role');
  await d.locator('#P31_NAME').fill('shop_manager');
  contains('a role name must be unique', await app.error(d.getByRole('button', { name: 'Save', exact: true }), d), 'already exists');
  await save('temp_role');
  await app.dialogClosed('Role');
  await page.waitForTimeout(500);
  await page.locator('#rst-roles a').filter({ hasText: /^temp_role$/ }).click();
  await save('temp_role_renamed');
  await app.dialogClosed('Role');
  await page.waitForTimeout(500);
  check('a role can be renamed', (await app.rows('#rst-roles tbody tr')).some(r => r.startsWith('temp_role_renamed ')));
  await page.locator('#rst-roles a').filter({ hasText: /^temp_role_renamed$/ }).click();
  d = app.dialog('Role');
  await d.getByRole('button', { name: 'Delete' }).click();
  await app.confirm();
  await app.dialogClosed('Role');
  await page.waitForTimeout(500);
  check('a role can be deleted', !(await app.rows('#rst-roles tbody tr')).some(r => r.startsWith('temp_role')));
}, page);

let token;
await run('9  Privileges and OAuth clients', async () => {
  // privilege
  await app.go('privileges');
  contains('the privilege list explains that it is empty', await page.locator('.rst-empty').innerText(), 'No privileges');
  await app.button('Create Privilege').click();
  let d = app.dialog('Privilege');
  await d.locator('#P21_NAME').fill('shop admin');
  contains('a privilege name must not contain spaces', await app.error(d.getByRole('button', { name: 'Save', exact: true }), d), 'must not contain spaces');
  await d.locator('#P21_NAME').fill('shop.admin');
  await d.locator('#P21_LABEL').fill('Shop administration');
  await d.locator('#P21_PATTERNS').fill('/secret/*\n/internal/*');
  let frame = await frameOf('Privilege');
  await app.set('P21_ROLES', ['shop_manager'], frame);
  await app.set('P21_MODULES', ['shop.v1'], frame);
  await d.getByRole('button', { name: 'Save', exact: true }).click();
  await app.dialogClosed('Privilege');
  await page.waitForTimeout(500);
  let row = (await app.rows('#rst-privileges tbody tr'))[0];
  check('the privilege shows role, module and patterns', ['shop.admin', 'Shop administration', 'shop_manager', 'shop.v1', '/secret/*', '/internal/*'].every(t => row.includes(t)), row);
  equal('the protected module asks for authentication', await eventually(status(A, '/shop/v1/products/'), 401), 401);
  await openModule('shop.v1');
  equal('the module form shows its privilege', await page.inputValue('#P11_PRIVILEGE'), 'shop.admin');
  await app.go('modules');
  check('the module list shows the protection', (await app.rows('#rst-modules tbody tr')).find(r => r.startsWith('shop.v1 ')).includes('shop.admin'));

  await app.go('privileges');
  await page.locator('#rst-privileges a').filter({ hasText: /^shop\.admin$/ }).click();
  d = app.dialog('Privilege');
  equal('the dialog loads the patterns', await d.locator('#P21_PATTERNS').inputValue(), '/internal/*\n/secret/*');
  await d.locator('#P21_NAME').fill('shop.manage');
  await d.getByRole('button', { name: 'Save', exact: true }).click();
  await app.dialogClosed('Privilege');
  await page.waitForTimeout(500);
  row = (await app.rows('#rst-privileges tbody tr'))[0];
  check('a privilege can be renamed and keeps its links', row.startsWith('shop.manage') && row.includes('shop.v1') && row.includes('shop_manager'), row);
  equal('the module is still protected', (await rest(A, 'GET', '/shop/v1/products/')).status, 401);
  await app.button('Create Privilege').click();
  d = app.dialog('Privilege');
  await d.locator('#P21_NAME').fill('shop.manage');
  contains('a privilege name must be unique', await app.error(d.getByRole('button', { name: 'Save', exact: true }), d), 'already exists');
  await d.getByRole('button', { name: 'Cancel' }).click();
  await app.dialogClosed('Privilege');

  // client
  await app.go('oauth-clients');
  contains('the client list explains that it is empty', await page.locator('.rst-empty').innerText(), 'No OAuth clients');
  await app.button('Register Client').click();
  d = app.dialog('OAuth Client');
  await d.locator('#P41_NAME').fill('shop-app');
  await d.locator('#P41_SUPPORT_EMAIL').fill('shop@example.com');
  await d.locator('#P41_GRANT_TYPE').selectOption('authorization_code');
  const missing = await app.error(d.getByRole('button', { name: 'Register Client' }), d);
  check('an authorization code client needs a redirect URI and a description', missing.includes('redirect URI') && missing.includes('description'), missing);
  await d.locator('#P41_GRANT_TYPE').selectOption('client_credentials');
  frame = await frameOf('OAuth Client');
  await app.set('P41_ROLES', ['shop_manager'], frame);
  await d.getByRole('button', { name: 'Register Client' }).click();
  await d.locator('.rst-credentials.is-new').waitFor({ timeout: 20000 });
  contains('the client secret is shown after registration', await d.locator('.rst-credentials').innerText(), 'Copy the client secret now');
  const clientId = await d.locator('#rst-client-id').innerText();
  const secret = await d.locator('#rst-client-secret').innerText();
  const tokenUrl = await d.locator('#rst-token-url').innerText();
  equal('the token URL belongs to the schema', tokenUrl, `${cfg.ords}/${A}/oauth/token`);
  await d.locator('button').filter({ has: page.locator('span.t-Button-label', { hasText: /^Close$/ }) }).click();
  await app.dialogClosed('OAuth Client');
  await page.waitForTimeout(500);
  row = (await app.rows('#rst-clients tbody tr'))[0];
  check('the client is listed with its role', ['shop-app', 'Client credentials', 'shop_manager'].every(t => row.includes(t)), row);

  const getToken = async (id, s) => {
    const response = await fetch(tokenUrl, {
      method: 'POST',
      headers: { Authorization: 'Basic ' + Buffer.from(`${id}:${s}`).toString('base64'), 'Content-Type': 'application/x-www-form-urlencoded' },
      body: 'grant_type=client_credentials'
    });
    return { status: response.status, token: response.ok ? (await response.json()).access_token : null };
  };
  let t = await getToken(clientId, secret);
  equal('the client gets an access token', t.status, 200);
  token = t.token;
  equal('the token opens the protected module', (await rest(A, 'GET', '/shop/v1/products/', { headers: { Authorization: 'Bearer ' + token } })).status, 200);

  // request console with and without the token
  await openHandler('shop.v1', 'products/', 'GET');
  await page.locator('.rst-try-send').click();
  await page.locator('.rst-try-result.is-visible').waitFor();
  contains('the console shows that authentication is needed', await page.locator('.rst-try-code').innerText(), '401');
  await page.fill('.rst-try-headers', 'Authorization: Bearer ' + token);
  await page.locator('.rst-try-send').click();
  await page.waitForFunction(() => document.querySelector('.rst-try-code').textContent.startsWith('200'), null, { timeout: 15000 });
  contains('the console sends request headers', await page.locator('.rst-try-code').innerText(), '200');

  // secret is shown once, rotation, changes
  await app.go('oauth-clients');
  await page.locator('#rst-clients a').filter({ hasText: /^shop-app$/ }).click();
  d = app.dialog('OAuth Client');
  await d.locator('#P41_NAME').waitFor();
  equal('the secret is not shown again', await d.locator('#rst-client-secret').count(), 0);
  check('the grant type cannot be changed', await d.locator('select#P41_GRANT_TYPE').count() === 0 || await d.locator('#P41_GRANT_TYPE').isDisabled());
  await d.locator('#P41_DESCRIPTION').fill('Shop front end');
  await d.locator('#P41_NAME').fill('shop-frontend');
  await d.getByRole('button', { name: 'Save', exact: true }).click();
  await d.locator('#P41_DESCRIPTION').waitFor();
  await page.waitForTimeout(1500);
  d = app.dialog('OAuth Client');
  equal('a client can be renamed', await d.locator('#P41_NAME').inputValue(), 'shop-frontend');
  await d.getByRole('button', { name: 'Generate New Secret' }).click();
  await app.confirm();
  await d.locator('.rst-credentials.is-new').waitFor({ timeout: 20000 });
  const newSecret = await d.locator('#rst-client-secret').innerText();
  check('a new secret is generated', newSecret && newSecret !== secret);
  equal('the old secret stops working', (await getToken(clientId, secret)).status, 401);
  equal('the new secret works', (await getToken(clientId, newSecret)).status, 200);
  await d.getByRole('button', { name: 'Delete' }).click();
  await app.confirm();
  await app.dialogClosed('OAuth Client');
  await page.waitForTimeout(500);
  equal('a client can be deleted', (await app.rows('#rst-clients tbody tr')).length, 0);
  equal('a deleted client gets no token', (await getToken(clientId, newSecret)).status, 401);

  // make the module public again through the module form
  await openModule('shop.v1');
  await page.selectOption('#P11_PRIVILEGE', '');
  await app.nav(app.button('Save'));
  equal('removing the privilege makes the module public', await eventually(status(A, '/shop/v1/products/'), 200), 200);
  await page.selectOption('#P11_PRIVILEGE', 'shop.manage');
  await app.nav(app.button('Save'));
  equal('the module form can protect the module again', await eventually(status(A, '/shop/v1/products/'), 401), 401);
  await app.go('privileges');
  row = (await app.rows('#rst-privileges tbody tr'))[0];
  check('the privilege kept its roles and patterns', ['shop.manage', 'shop_manager', 'shop.v1', '/secret/*'].every(t => row.includes(t)), row);
  await page.locator('#rst-privileges a').filter({ hasText: /^shop\.manage$/ }).click();
  d = app.dialog('Privilege');
  await d.locator('#P21_NAME').waitFor();
  await app.set('P21_MODULES', [], await frameOf('Privilege'));
  await d.getByRole('button', { name: 'Save', exact: true }).click();
  await app.dialogClosed('Privilege');
  equal('the privilege dialog can release the module too', await eventually(status(A, '/shop/v1/products/'), 200), 200);
  await app.go('privileges');
  row = (await app.rows('#rst-privileges tbody tr'))[0];
  check('the privilege itself is kept', row.startsWith('shop.manage') && !row.includes('shop.v1'), row);
}, page);

await run('10 AutoREST', async () => {
  await app.go('autorest');
  contains('the object list explains that it is empty', await page.locator('.rst-empty').innerText(), 'No objects');
  const open = async () => { await page.locator('#rst-objects a').filter({ hasText: /^PRODUCTS$/ }).click(); return app.dialog('AutoREST Object'); };
  const saveClose = async (d) => { await d.getByRole('button', { name: 'Save', exact: true }).click(); await app.dialogClosed('AutoREST Object'); await page.waitForTimeout(500); };
  await app.button('Enable Object').click();
  let d = app.dialog('AutoREST Object');
  contains('an object has to be chosen', await app.error(d.getByRole('button', { name: 'Save', exact: true }), d), 'must have some value');
  await d.locator('#P51_OBJECT').selectOption('TABLE:PRODUCTS');
  await d.locator('#P51_ALIAS').fill('prods');
  let frame = await frameOf('AutoREST Object');
  await app.set('P51_AUTH', 'N', frame);
  await saveClose(d);
  let row = (await app.rows('#rst-objects tbody tr'))[0];
  check('the table is listed as enabled and public', ['PRODUCTS', 'Table', 'Enabled', 'Public', `${cfg.ords}/${A}/prods/`].every(t => row.includes(t)), row);
  equal('ORDS publishes the table', await eventually(status(A, '/prods/'), 200), 200);
  check('with its rows', (await rest(A, 'GET', '/prods/')).json.items.length > 0);
  d = await open();
  check('the object cannot be changed afterwards', await d.locator('select#P51_OBJECT').count() === 0 || await d.locator('#P51_OBJECT').isDisabled());
  frame = await frameOf('AutoREST Object');
  await app.set('P51_AUTH', 'Y', frame);
  await d.locator('#P51_ALIAS').fill('items');
  await saveClose(d);
  equal('with authorization the table is protected', await eventually(status(A, '/items/'), 401), 401);
  equal('the old alias is gone', await eventually(status(A, '/prods/'), 404), 404);
  d = await open();
  frame = await frameOf('AutoREST Object');
  await app.set('P51_ENABLED', 'N', frame);
  await saveClose(d);
  contains('a disabled object stays in the list', (await app.rows('#rst-objects tbody tr'))[0], 'Disabled');
  equal('a disabled object is not published', await eventually(status(A, '/items/'), 404), 404);
  d = await open();
  frame = await frameOf('AutoREST Object');
  equal('the dialog shows that it is disabled', await app.value('P51_ENABLED', frame), 'N');
  await app.set('P51_ENABLED', 'Y', frame);
  await saveClose(d);
  equal('it can be enabled again with its settings', await eventually(status(A, '/items/'), 401), 401);
  d = await open();
  await d.getByRole('button', { name: 'Remove' }).click();
  await app.confirm();
  await app.dialogClosed('AutoREST Object');
  await page.waitForTimeout(500);
  equal('the REST definition of the object can be removed', (await app.rows('#rst-objects tbody tr')).length, 0);
  equal('the table itself is untouched', sql('e2e_rest', "select count(*) from user_tables where table_name = 'PRODUCTS';")[0].trim(), '1');
}, page);

await run('11 Search and navigation', async () => {
  await app.go('search');
  await page.fill('#P16_SEARCH', 'PRODUCTS');
  await Promise.all([page.waitForNavigation(), page.keyboard.press('Enter')]);
  await page.waitForLoadState('networkidle');
  let rows = await app.rows('.rst-table tbody tr');
  equal('the search finds every handler that uses the table', rows.length, 10);
  check('a hit shows handler, module and the line', rows.some(r => r.startsWith('GET /shop/v1/products/ shop.v1 2 from products')), rows[0]);
  await page.fill('#P16_SEARCH', 'RETURNING product_id');
  await app.nav(app.button('Search'));
  rows = await app.rows('.rst-table tbody tr');
  check('the search ignores case and shows the line number', rows.length === 2 && rows[0].includes(' 4 returning product_id into :id;'), rows.join(' | '));
  await app.nav('.rst-table a.rst-path >> nth=0');
  equal('a hit opens the handler', await page.title(), 'Handler');
  await app.go('search');
  await page.fill('#P16_SEARCH', 'zzzqqq');
  await app.nav(app.button('Search'));
  contains('no hit is reported', await page.locator('.rst-empty').innerText(), 'No handler contains');

  await openHandler('shop.v1', 'products/:id', 'PUT');
  check('the tree marks the current handler', await page.locator('.rst-tree .rst-method--put.is-current').count() === 1);
  check('the module of the current handler is open', await page.locator('.rst-tree .rst-node--module.is-open').count() >= 1);
  const copyNode = page.locator('.rst-tree .rst-node--module').filter({ hasText: 'shop.v1.copy' });
  if ((await copyNode.getAttribute('class')).includes('is-open')) {
    await copyNode.locator('.rst-node-toggle').click();
  }
  await page.fill('.rst-tree-search', 'copy');
  equal('the tree filter hides other modules', await page.locator('.rst-tree .rst-node--module:visible').count(), 1);
  check('and opens the module it finds', (await copyNode.getAttribute('class')).includes('is-open'));
  await page.fill('.rst-tree-search', '');
  await copyNode.locator('.rst-node-toggle').click();
  check('a module can be closed', !(await copyNode.getAttribute('class')).includes('is-open'));
  await copyNode.locator('.rst-node-toggle').click();
  await app.go('modules');
  check('the tree remembers opened modules', await page.locator('.rst-tree .rst-node--module.is-open').filter({ hasText: 'shop.v1.copy' }).count() === 1);
  equal('the navigation menu has all entries', await page.locator('.t-TreeNav [role=treeitem], .t-TreeNav li').count() >= 10, true);
  await app.go('home');
  equal('the dashboard counts modules, templates, handlers, privileges and roles', (await page.locator('.rst-stat-value').allInnerTexts()).join(','), '2,4,10,1,1,0,0');
  contains('the dashboard mentions the unpublished module', await page.locator('.rst-stat').first().innerText(), '1 not published');
  equal('the dashboard lists the handlers changed last', (await app.rows('.rst-table tbody tr')).length, 8);
}, page);

let schemaExport, moduleExport, handlerExport, sqlExport;
await run('12 Export', async () => {
  await app.go('export');
  contains('the preview shows the exchange format', await page.locator('#rst-export-preview').innerText(), '"format": "restaurant-ords"');
  schemaExport = await app.download(app.button('Download'));
  equal('a schema export is named after the schema', schemaExport.name, 'e2e_rest-rest-services.ords.json');
  let doc = JSON.parse(schemaExport.text);
  equal('it contains both modules', doc.modules.map(m => m.name).join(','), 'shop.v1,shop.v1.copy');
  check('it contains role and privilege', doc.roles.includes('shop_manager') && doc.privileges[0].name === 'shop.manage', JSON.stringify(doc.roles));
  check('it has no export details by default', doc.meta === undefined);
  check('source code is exported line by line', Array.isArray(doc.modules[0].templates[0].handlers[0].source) && doc.modules[0].templates[0].handlers[0].source.length === 3);
  await app.go('export');
  const again = await app.download(app.button('Download'));
  check('the same services give the same file', again.buffer.equals(schemaExport.buffer));

  await app.set('P60_INCLUDE_META', 'Y');
  await app.set('P60_INCLUDE_SECURITY', 'N');
  doc = JSON.parse((await app.download(app.button('Download'))).text);
  check('export details can be added', doc.meta && doc.meta.schema === 'E2E_REST' && /^\d{4}-\d\d-\d\dT/.test(doc.meta.exportedAt), JSON.stringify(doc.meta));
  check('privileges and roles can be left out', doc.privileges === undefined && doc.roles === undefined);
  await app.set('P60_INCLUDE_META', 'N');
  await app.set('P60_INCLUDE_SECURITY', 'Y');

  await page.check('#P60_FORMAT input[value="SQL"]');
  await app.nav(app.button('Refresh Preview'));
  contains('the preview follows the format', await page.locator('#rst-export-preview').innerText(), 'ords.define_module(');
  const script = await app.download(app.button('Download'));
  check('the SQL export is a script with ORDS calls', script.name === 'e2e_rest-rest-services.ords.sql' && script.text.includes('ords.define_handler(') && script.text.trimEnd().endsWith('/'), script.name);
  await page.check('#P60_FORMAT input[value="ZIP"]');
  const zip = await app.download(app.button('Download'));
  check('the ZIP export is an archive', zip.name === 'e2e_rest-rest-services.ords.zip' && zip.buffer.subarray(0, 2).toString() === 'PK', zip.name);
  fs.copyFileSync(zip.file, path.join(cfg.output, 'schema.zip'));

  await page.check('#P60_FORMAT input[value="JSON"]');
  await page.check('#P60_SCOPE input[value="MODULES"]');
  check('the module list appears for selected modules', await page.locator('#P60_MODULES').isVisible());
  contains('without a selection nothing is downloaded', await app.error(app.button('Download')), 'Select at least one module');
  await app.nav(app.button('Refresh Preview'));
  contains('and the preview says why it is empty', await page.locator('.rst-empty').innerText(), 'Select at least one module');
  await page.locator('#P60_MODULES label').filter({ hasText: /^shop\.v1$/ }).click();
  moduleExport = await app.download(app.button('Download'));
  equal('a single selected module names the file', moduleExport.name, 'shop.v1.ords.json');
  equal('only the selected module is exported', JSON.parse(moduleExport.text).modules.length, 1);

  await openModule('shop.v1');
  await app.nav(app.button('Export'));
  equal('the module page opens the export for the module', await page.locator('#P60_SCOPE input:checked').getAttribute('value'), 'MODULE');
  await openTemplate('shop.v1', 'products/:id');
  await app.nav(app.button('Export'));
  equal('the template page opens the export for the template', await page.locator('#P60_SCOPE input:checked').getAttribute('value'), 'TEMPLATE');
  check('an archive is not offered for a template', !(await page.locator('#P60_FORMAT input[value="ZIP"]').isVisible()));
  const templateExport = await app.download(app.button('Download'));
  doc = JSON.parse(templateExport.text);
  check('a template export is partial and has its handlers', templateExport.name === 'shop.v1--products-id.ords.json' && doc.modules[0].partial === true && doc.modules[0].templates[0].handlers.length === 3, templateExport.name);

  await openHandler('shop.v1', 'products/', 'GET');
  await app.nav(app.button('Export'));
  handlerExport = await app.download(app.button('Download'));
  doc = JSON.parse(handlerExport.text);
  check('a handler export contains just the handler', handlerExport.name === 'shop.v1--products--get.ords.json' && doc.modules[0].templates.length === 1 && doc.modules[0].templates[0].handlers.length === 1, handlerExport.name);
  await page.check('#P60_FORMAT input[value="SQL"]');
  const handlerScript = await app.download(app.button('Download'));
  check('the script of a handler does not redefine its template', handlerScript.text.includes('ords.define_handler(') && !handlerScript.text.includes('ords.define_template('));

  await app.go('modules');
  const quick = await app.download(page.locator('#rst-modules tr').filter({ hasText: 'shop.v1.copy' }).locator('.rst-icon-link'));
  equal('the list offers a direct download', quick.name, 'shop.v1.copy.ords.json');
  await openModule('shop.v1');
  await app.nav(app.button('Export'));
  await page.check('#P60_FORMAT input[value="SQL"]');
  sqlExport = await app.download(app.button('Download'));
  fs.copyFileSync(sqlExport.file, path.join(cfg.output, 'module.sql'));
}, page);

await run('13 Import', async () => {
  await app.go('review-import');
  equal('the review cannot be opened without a file', await page.title(), 'Import');
  contains('the import needs a file or text', await app.error(app.button('Continue')), 'Choose a file or paste');

  await importFile(schemaExport.file);
  equal('the review opens', await page.title(), 'Review Import');
  contains('the review names the file', await page.locator('.t-HeroRegion').innerText(), 'e2e_rest-rest-services.ords.json');
  equal('an export of the schema itself is unchanged', await planSummary(), '18 unchanged');
  equal('roles and privileges are part of the comparison', (await planRows()).slice(0, 2).join(' | '), 'Role shop_manager Unchanged | Privilege shop.manage Unchanged');

  // a changed handler, a new template, and a template that is missing in the file
  const doc = JSON.parse(moduleExport.text);
  const module = doc.modules[0];
  module.templates.find(t => t.uriTemplate === 'products/').handlers.find(h => h.method === 'GET').source.push(' fetch first 100 rows only');
  module.templates = module.templates.filter(t => t.uriTemplate !== 'products/:id');
  module.templates.push({ uriTemplate: 'cheap/', handlers: [{ method: 'GET', sourceType: 'json/collection', source: ['select name from products where price < 5'] }] });
  const changed = path.join(cfg.output, 'changed.json');
  fs.writeFileSync(changed, JSON.stringify(doc, null, 2));
  await importFile(changed);
  contains('the review counts new, changed and unchanged elements', await planSummary(), '2 new 1 changed');
  let rows = await planRows();
  check('the changed handler is marked', rows.some(r => r === 'GET Changed'), rows.join(' | '));
  check('the new template is marked', rows.some(r => r === 'cheap/ New'));
  check('what is only in the schema is listed', rows.some(r => r === 'products/:id Only in the schema'));
  const before = handlerTimes('shop.v1');
  await page.waitForTimeout(1500);
  await app.nav(app.button('Import'));
  equal('the import reports its result', await app.success(), '1 module imported.');
  await openModule('shop.v1');
  equal('merging keeps what is only in the schema', (await app.rows('.rst-table tbody tr')).length, 3);
  const after = handlerTimes('shop.v1');
  check('only the changed handler was written', after['GET products/'] !== before['GET products/'] && after['POST products/'] === before['POST products/'] && after['PUT products/:id'] === before['PUT products/:id'], JSON.stringify({ before, after }));
  equal('the new template works', (await rest(A, 'GET', '/shop/v1/cheap/')).status, 200);

  await importFile(changed);
  equal('after the import the file is unchanged, the rest only in the schema', await planSummary(), '6 unchanged 1 only in the schema');
  await page.check('#P71_MODE input[value="REPLACE"]');
  await app.nav(app.button('Import'));
  await openModule('shop.v1');
  equal('replacing removes what is not in the file', (await app.rows('.rst-table tbody tr')).length, 2);
  equal('the removed template is gone', (await rest(A, 'GET', '/shop/v1/products/1')).status, 404);
  await importFile(moduleExport.file);
  await page.check('#P71_MODE input[value="REPLACE"]');
  await app.nav(app.button('Import'));
  await openModule('shop.v1');
  equal('replacing with the original restores the module', (await app.rows('.rst-table tbody tr')).map(r => r.split(' ')[0]).join(','), 'products/,products/:id');
  equal('and its handlers', (await rest(A, 'GET', '/shop/v1/products/1')).status, 200);

  // skip, with a second module that is new
  const two = JSON.parse(changed ? fs.readFileSync(changed, 'utf8') : '{}');
  two.modules.push({ name: 'new.v1', basePath: '/new/v1/', templates: [{ uriTemplate: 'x', handlers: [{ method: 'GET', sourceType: 'json/collection', source: 'select 1 x from dual' }] }] });
  const twoFile = path.join(cfg.output, 'two.json');
  fs.writeFileSync(twoFile, JSON.stringify(two));
  await importFile(twoFile);
  await page.check('#P71_MODE input[value="SKIP"]');
  await app.nav(app.button('Import'));
  equal('skipping imports new modules only', await app.success(), '1 module imported, 1 skipped.');
  equal('a source given as one string is accepted', (await rest(A, 'GET', '/new/v1/x')).status, 200);
  await openModule('shop.v1');
  equal('the skipped module is untouched', (await app.rows('.rst-table tbody tr')).length, 2);

  // under another name, not published
  await importFile(moduleExport.file);
  check('a single module can get another name', await page.locator('#P71_NEW_NAME').isVisible());
  await page.fill('#P71_NEW_NAME', 'shop.v2');
  await page.fill('#P71_NEW_BASE_PATH', 'shop/v2');
  await page.selectOption('#P71_STATUS', 'NOT_PUBLISHED');
  await app.nav(app.button('Import'));
  const list = await app.rows('#rst-modules tbody tr');
  check('the module is imported under the new name, not published', list.some(r => r.startsWith('shop.v2 ') && r.includes('/shop/v2/') && r.includes('Not published')), list.join(' | '));
  await importFile(twoFile);
  check('a new name is not offered for several modules', await page.locator('#P71_NEW_NAME').count() === 0);

  // nothing selected
  for (const box of await page.locator('#P71_MODULES input[type=checkbox]').all()) { await box.uncheck(); }
  await app.nav(app.button('Import'));
  equal('without a selected module nothing is imported', await app.success(), '0 modules imported.');

  // a single handler never removes anything
  const single = JSON.parse(handlerExport.text);
  single.modules[0].templates[0].handlers[0].comments = 'imported on its own';
  const singleFile = path.join(cfg.output, 'single.json');
  fs.writeFileSync(singleFile, JSON.stringify(single));
  await importFile(singleFile);
  contains('the review says that the file is partial', (await planRows())[0], 'partial export');
  await page.check('#P71_MODE input[value="REPLACE"]');
  await app.nav(app.button('Import'));
  equal('a partial file keeps the rest of the module, even with replace', sql('e2e_rest', "select count(*) from user_ords_handlers h join user_ords_templates t on t.id = h.template_id join user_ords_modules m on m.id = t.module_id where m.name = 'shop.v1';")[0].trim(), '5');
  equal('and the handler is updated', sql('e2e_rest', "select h.comments from user_ords_handlers h join user_ords_templates t on t.id = h.template_id join user_ords_modules m on m.id = t.module_id where m.name = 'shop.v1' and t.uri_template = 'products/' and h.method = 'GET';")[0].trim(), 'imported on its own');

  // pasted text and archive
  await importText(moduleExport.text);
  await app.nav(app.button('Continue'));
  check('pasted JSON is accepted', (await page.title()) === 'Review Import' && (await page.locator('.t-HeroRegion').innerText()).includes('Pasted text'));
  await importFile(path.join(cfg.output, 'schema.zip'));
  contains('an archive is read file by file', await page.locator('.t-HeroRegion').innerText(), 'schema.zip');
  check('the archive contains the modules and the security', (await planRows()).filter(r => /^(shop\.v1|shop\.v1\.copy|Privilege shop\.manage|Role shop_manager) /.test(r)).length === 4, (await planRows()).join(' | ').slice(0, 300));

  // files that are not usable
  const base = { format: 'restaurant-ords', version: 1 };
  const handler = (h) => ({ ...base, modules: [{ name: 'bad.v1', basePath: '/bad/', templates: [{ uriTemplate: 't', handlers: [h] }] }] });
  for (const [name, text, expected] of [
    ['text that is not JSON', 'this is not json', 'not a valid JSON'],
    ['a foreign JSON document', '{"format": "something-else"}', 'not a RESTaurant export'],
    ['a newer format version', JSON.stringify({ ...base, version: 2 }), 'format version 2'],
    ['an empty document', JSON.stringify(base), 'does not contain any'],
    ['a module without a base path', JSON.stringify({ ...base, modules: [{ name: 'bad.v1' }] }), 'base path is missing'],
    ['an unsupported method', JSON.stringify(handler({ method: 'PATCH', sourceType: 'plsql/block', source: 'begin null; end;' })), 'not a supported method'],
    ['a POST handler that is a query', JSON.stringify(handler({ method: 'POST', sourceType: 'json/collection', source: 'select 1 from dual' })), 'needs the source type'],
    ['a handler without source', JSON.stringify(handler({ method: 'GET', sourceType: 'json/collection' })), 'has no source'],
    ['a template that is defined twice', JSON.stringify({ ...base, modules: [{ name: 'bad.v1', basePath: '/bad/', templates: [{ uriTemplate: 't' }, { uriTemplate: 't' }] }] }), 'defined twice']
  ]) {
    await importText(text);
    contains(`${name} is rejected`, await app.error(app.button('Continue')), expected);
  }
  const notAnExport = path.join(cfg.output, 'notes.txt');
  fs.writeFileSync(notAnExport, 'hello');
  await app.go('import');
  await page.setInputFiles('input[type=file]', notAnExport);
  contains('a file of another type is rejected', await app.error(app.button('Continue')), 'Invalid file type');
  equal('rejected files changed nothing', sql('e2e_rest', "select count(*) from user_ords_modules where name = 'bad.v1';")[0].trim(), '0');
}, page);

await run('14 Another schema', async () => {
  const pageB = await context.newPage();
  pageB.on('dialog', d => d.accept());
  const other = new App(pageB, 'restaurant-e2e_rest_b');
  await other.login();
  check('the second copy works on its own schema', (await pageB.locator('.t-HeroRegion').innerText()).includes('E2E_REST_B') && await pageB.locator('.t-Alert--warning').count() === 1);
  await other.go('schema');
  await other.set('P80_ENABLED', 'Y');
  await pageB.fill('#P80_PATTERN', B);
  await other.nav(other.button('Save'));

  await other.go('import');
  await pageB.setInputFiles('input[type=file]', schemaExport.file);
  await other.nav(other.button('Continue'));
  equal('in an empty schema everything is new', (await pageB.locator('.rst-toolbar').first().innerText()).replace(/\s+/g, ' ').trim(), '18 new');
  await other.nav(other.button('Import'));
  equal('modules, roles and privileges are imported', await other.success(), '2 modules imported, 2 roles and privileges applied.');
  const r = await rest(B, 'GET', '/shop/v1/products/1');
  check('the imported service works in the other schema', r.status === 200 && r.json.name === 'Product 1', `${r.status}`);
  await other.go('privileges');
  contains('the privilege arrived', (await other.rows('#rst-privileges tbody tr'))[0], 'shop.manage');
  await other.go('export');
  await pageB.check('#P60_SCOPE input[value="MODULES"]');
  await pageB.locator('#P60_MODULES label').filter({ hasText: /^shop\.v1\.copy$/ }).click();
  const back = await other.download(other.button('Download'));
  const original = JSON.parse(schemaExport.text).modules.find(m => m.name === 'shop.v1.copy');
  equal('an export from the other schema is identical', JSON.stringify(JSON.parse(back.text).modules[0]), JSON.stringify(original));

  // the SQL script as the way without the application
  sql('e2e_rest_b', "begin ords.delete_module('shop.v1'); commit; end;\n/");
  equal('the module is removed for the script test', await eventually(status(B, '/shop/v1/products/1'), 404), 404);
  const out = sqlFile('e2e_rest_b', 'tests/e2e/output/module.sql');
  check('the SQL script runs in SQLcl', !/ORA-|SP2-|PLS-/.test(out), out.slice(-300));
  equal('the script recreated the service', await eventually(status(B, '/shop/v1/products/1'), 200), 200);
  await other.go('import');
  await pageB.setInputFiles('input[type=file]', moduleExport.file);
  await other.nav(other.button('Continue'));
  equal('what the script created equals the JSON export', (await pageB.locator('.rst-toolbar').first().innerText()).replace(/\s+/g, ' ').trim(), '8 unchanged');
  await pageB.close();
}, page);

await run('15 Checking all handlers', async () => {
  await app.go('modules');
  await app.nav(app.button('Check Handlers'));
  contains('all handlers of the schema compile', await planSummary(), 'All 16 handlers compile');
  await openHandler('shop.v1', 'products/:id', 'GET');
  await app.setSource('select product_id, name\n  from products\n where product_idx = :id');
  await app.nav(app.button('Save'));
  equal('a handler that does not compile can be saved', await app.success(), 'Handler saved.');
  await app.editor();
  const c = await app.checkResult();
  check('the error is shown when the handler is opened', c.state === 'error' && c.text.includes('Line 3, column 8'), c.text);
  await openModule('shop.v1');
  await app.nav(app.button('Check Handlers'));
  contains('the check of a module finds it', await planSummary(), '1 of 5 handlers do not compile');
  contains('the check names the module', await planSummary(), 'Module shop.v1');
  const row = (await app.rows('.rst-table >> nth=0 >> tbody tr'))[0];
  check('the broken handler is listed with position and message', row.startsWith('GET /shop/v1/products/:id shop.v1 3:8 ORA-00904'), row);
  await app.nav('.rst-table >> nth=0 >> a.rst-path');
  await app.editor();
  await app.setSource(SOURCE.item);
  await page.getByRole('button', { name: 'Check Source' }).click();
  await page.waitForTimeout(400);
  equal('the check button confirms the fix', (await app.checkResult()).state, 'ok');
  await app.nav(app.button('Save'));
  await app.go('modules');
  await app.nav(app.button('Check Handlers'));
  contains('after the fix everything compiles', await planSummary(), 'All 16 handlers compile');
}, page);

await run('16 Things that go wrong', async () => {
  // an element that was deleted by someone else
  await openModule('shop.v2');
  const moduleUrl = page.url();
  await app.nav('.rst-table a.rst-path >> nth=0');
  const templateUrl = page.url();
  await app.nav('.rst-table a.rst-method >> nth=0');
  const handlerUrl = page.url();
  sql('e2e_rest', "begin ords.delete_module('shop.v2'); commit; end;\n/");
  for (const [what, url] of [['handler', handlerUrl], ['template', templateUrl], ['module', moduleUrl]]) {
    await page.goto(url);
    await page.waitForLoadState('networkidle');
    equal(`a deleted ${what} leads back to the module list`, await page.title(), 'Modules');
  }
  // a manipulated link
  await openModule('shop.v1');
  const tampered = page.url().replace(/p11_id=\d+/, 'p11_id=1');
  await page.goto(tampered);
  await page.waitForLoadState('networkidle');
  check('a manipulated link is refused', await page.locator('#P11_NAME').count() === 0, await page.title());
  // without a session
  const anonymous = await browser.newContext();
  const stranger = await anonymous.newPage();
  await stranger.goto(app.url + 'modules');
  await stranger.waitForLoadState('networkidle');
  check('without a session the login page appears', await stranger.locator('#P9999_USERNAME').count() === 1);
  await anonymous.close();
}, page);

await run('17 The authorization scheme', async () => {
  // the delivered query lets everyone in; a copy with a query that returns no row lets nobody in
  const installer = fs.readFileSync(path.join(cfg.repo, 'dist', 'restaurant.sql'), 'utf8');
  check('the installer contains the delivered query', installer.includes("'sql_query', 'select 1 from dual')"));
  fs.writeFileSync(path.join(cfg.output, 'restaurant-locked.sql'), installer.replace("'sql_query', 'select 1 from dual')", "'sql_query', 'select 1 from dual where 1 = 0')"));
  fs.writeFileSync(path.join(cfg.output, 'install-locked.sql'), [
    'set define off verify off feedback off',
    'begin',
    "    apex_application_install.set_workspace('E2E');",
    "    apex_application_install.set_schema('E2E_REST');",
    '    apex_application_install.set_application_id(202);',
    "    apex_application_install.set_application_alias('RESTAURANT-LOCKED');",
    '    apex_application_install.generate_offset;',
    'end;',
    '/',
    '@@restaurant-locked.sql',
    'exit', ''].join('\n'));
  sqlFile('e2e_rest', 'tests/e2e/output/install-locked.sql');
  const locked = new App(await context.newPage(), 'restaurant-locked');
  await locked.login();
  const text = await locked.page.locator('body').innerText();
  contains('IST_ADMIN without a row locks the application', text, 'not allowed to manage the RESTful services');
  check('no page content is shown', await locked.page.locator('.rst-stat').count() === 0);
  await locked.page.goto(locked.url + 'modules?session=' + locked.session);
  check('and no other page either', await locked.page.locator('#rst-modules').count() === 0);
  await locked.page.close();
  sql('e2e_rest', "begin apex_util.set_workspace('E2E'); apex_application_install.remove_application(202); commit; end;\n/");
}, page);

await run('18 A schema with many services', async () => {
  sql('e2e_rest', `
begin
    for m in 1 .. 30 loop
        ords.define_module(p_module_name => 'bulk.' || to_char(m, 'fm00'), p_base_path => '/bulk/' || m || '/');
        for t in 1 .. 5 loop
            ords.define_template(p_module_name => 'bulk.' || to_char(m, 'fm00'), p_pattern => 'things' || t || '/:id');
            ords.define_handler(p_module_name => 'bulk.' || to_char(m, 'fm00'), p_pattern => 'things' || t || '/:id', p_method => 'GET',
                p_source_type => 'json/item', p_source => 'select product_id, name, price' || chr(10) || '  from products' || chr(10) || ' where product_id = :id');
            ords.define_handler(p_module_name => 'bulk.' || to_char(m, 'fm00'), p_pattern => 'things' || t || '/:id', p_method => 'PUT',
                p_source_type => 'plsql/block', p_source => 'begin' || chr(10) || '    update products set price = :price where product_id = :id;' || chr(10) || 'end;');
        end loop;
    end loop;
    commit;
end;
/`);
  const limit = 15000;
  const report = [];
  const measure = async (name, fn) => { const ms = await timed(fn); report.push(`${name} ${ms} ms`); check(`${name} stays responsive (${ms} ms)`, ms < limit, `${ms} ms`); };
  await measure('module list with 33 modules', () => app.go('modules'));
  equal('all modules are listed', await page.locator('#rst-modules tbody tr').count(), 33);
  equal('the tree has all modules', await page.locator('.rst-tree .rst-node--module').count(), 33);
  await measure('opening a module', () => app.nav(page.locator('#rst-modules a.rst-strong').filter({ hasText: /^bulk\.17$/ })));
  await measure('opening a handler', async () => { await app.nav('.rst-table a.rst-method--put >> nth=0'); await app.editor(); await app.checkResult(); });
  await measure('search over 311 handlers', async () => { await app.go('search'); await page.fill('#P16_SEARCH', 'price'); await app.nav(app.button('Search')); });
  await measure('export preview of the schema', () => app.menu('Export'));
  equal('the menu opens the export with its defaults', await page.locator('#P60_SCOPE input:checked').getAttribute('value') + '/' + await page.locator('#P60_FORMAT input:checked').getAttribute('value'), 'SCHEMA/JSON');
  let bulk;
  await measure('download of the schema', async () => { bulk = await app.download(app.button('Download')); });
  check('the export is complete', JSON.parse(bulk.text).modules.length === 33, `${bulk.buffer.length} bytes`);
  await measure('compile check of 311 handlers', async () => { await app.go('modules'); await app.nav(app.button('Check Handlers')); });
  contains('all of them compile', await planSummary(), 'All 311 handlers compile');
  await measure('loading the export for import', () => importFile(bulk.file));
  contains('the review compares all of it', await planSummary(), 'unchanged');
  await measure('importing an unchanged schema', () => app.nav(app.button('Import')));
  console.log('        ' + report.join(' | '));
  sql('e2e_rest', "begin for m in ( select name from user_ords_modules where name like 'bulk.%' ) loop ords.delete_module(m.name); end loop; commit; end;\n/");
}, page);

await run('19 A small screen', async () => {
  await page.setViewportSize({ width: 390, height: 800 });
  for (const pagePath of ['home', 'modules', 'privileges', 'export', 'import', 'schema']) {
    await app.go(pagePath);
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
    check(`page ${pagePath} fits a phone`, overflow <= 2, `${overflow}px too wide`);
  }
  await openHandler('shop.v1', 'products/', 'GET');
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
  check('the handler page fits a phone', overflow <= 2, `${overflow}px too wide`);
  await page.screenshot({ path: path.join(cfg.output, 'phone-handler.png') });
  await page.setViewportSize({ width: 1440, height: 1000 });
}, page);

await run('20 Removing everything and signing out', async () => {
  await app.go('schema');
  await app.set('P80_ENABLED', 'N');
  await app.nav(app.button('Save'));
  equal('a disabled schema serves nothing', await eventually(status(A, '/shop/v1/products/'), 404), 404);
  equal('but keeps its definitions', sql('e2e_rest', 'select count(*) from user_ords_modules;')[0].trim(), '3');
  await app.set('P80_ENABLED', 'Y');
  await app.nav(app.button('Save'));
  equal('enabling brings the services back', await eventually(status(A, '/shop/v1/products/'), 200), 200);

  const expand = async () => { await page.locator('.t-Region-titleButton').first().click(); await page.locator('#P80_CONFIRM').waitFor({ state: 'visible' }); };
  await expand();
  await page.fill('#P80_CONFIRM', 'wrong name');
  await page.locator('button.t-Button--danger').filter({ hasText: 'Remove All REST Definitions' }).click();
  await page.locator('.ui-dialog--notification').waitFor();
  await app.confirm();
  await page.locator('.a-Notification-item').first().waitFor();
  contains('the removal needs the name of the schema', (await page.locator('.a-Notification-item').allInnerTexts()).join(' '), 'Nothing was removed');
  equal('and nothing was removed', sql('e2e_rest', 'select count(*) from user_ords_modules;')[0].trim(), '3');
  await page.fill('#P80_CONFIRM', 'e2e_rest');
  await page.locator('button.t-Button--danger').filter({ hasText: 'Remove All REST Definitions' }).click();
  await page.locator('.ui-dialog--notification').waitFor();
  await Promise.all([page.waitForNavigation(), app.confirm()]);
  await page.waitForLoadState('networkidle');
  equal('with the name everything is removed', await app.success(), 'All REST definitions of the schema were removed.');
  equal('no module is left', sql('e2e_rest', "select (select count(*) from user_ords_modules) || '/' || (select count(*) from user_ords_schemas) from dual;")[0].trim(), '0/0');
  await app.go('home');
  check('the dashboard warns again', await page.locator('.t-Alert--warning').count() === 1);
  equal('and counts nothing', (await page.locator('.rst-stat-value').allInnerTexts()).join(','), '0,0,0,0,0,0,0');

  await page.locator('.t-NavigationBar-item.has-username button, .t-NavigationBar button').filter({ hasText: /tester/i }).first().click();
  await app.nav(page.getByRole('menuitem', { name: 'Sign Out' }));
  check('signing out ends at the login page', await page.locator('#P9999_USERNAME').count() === 1);
  await page.goto(app.url + 'modules?session=' + app.session);
  await page.waitForLoadState('networkidle');
  check('the old session is no longer accepted', await page.locator('#P9999_USERNAME').count() === 1);
}, page);

await run('21 Browser console', async () => {
  equal('no JavaScript error occurred on any page', pageErrors.join(' | '), '');
});

await browser.close();
process.exit(summary() === 0 ? 0 : 1);
