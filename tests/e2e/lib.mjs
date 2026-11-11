// Helpers of the end-to-end walkthrough: configuration, a tiny check runner,
// access to the sandbox database and a page object for one installed copy of
// the application.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));

export const cfg = {
  ords: process.env.RESTAURANT_URL || 'http://localhost:8282/ords',
  workspace: 'e2e',
  user: 'TESTER',
  password: 'Restaurant_4U',
  container: process.env.RESTAURANT_ORDS_CONTAINER || 'restaurant-dev-ords-1',
  database: process.env.RESTAURANT_DATABASE || 'db:1521/FREEPDB1',
  output: path.join(here, 'output'),
  repo: path.resolve(here, '..', '..')
};
fs.mkdirSync(cfg.output, { recursive: true });

// ---------------------------------------------------------------- check runner
const results = [];
let section = '';

export function check(name, ok, detail) {
  results.push({ section, name, ok: !!ok, detail });
  console.log((ok ? '  ok    ' : '  FAIL  ') + name + (!ok && detail !== undefined ? '  ->  ' + String(detail).slice(0, 300) : ''));
}

export function equal(name, actual, expected) {
  check(name, actual === expected, `expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}

export function contains(name, actual, expected) {
  check(name, String(actual).includes(expected), `expected to contain ${JSON.stringify(expected)}, got ${JSON.stringify(String(actual).slice(0, 200))}`);
}

export async function run(title, fn, page) {
  section = title;
  console.log('\n' + title);
  try {
    await fn();
  } catch (error) {
    check('section ran to its end', false, String(error.message || error).split('\n')[0]);
    if (page) {
      await page.screenshot({ path: path.join(cfg.output, 'failed-' + title.replace(/[^a-z0-9]+/gi, '-').toLowerCase() + '.png') }).catch(() => {});
    }
  }
}

export function summary() {
  const failed = results.filter(r => !r.ok);
  console.log('\n' + '='.repeat(72));
  console.log(`${results.length} checks, ${results.length - failed.length} passed, ${failed.length} failed`);
  for (const f of failed) {
    console.log(`  FAIL  [${f.section}] ${f.name}  ->  ${String(f.detail).slice(0, 300)}`);
  }
  return failed.length;
}

// ---------------------------------------------------------------- database and REST
// runs statements with SQLcl inside the sandbox and returns the output lines
export function sql(schema, statements) {
  const connect = schema === 'sys'
    ? `sys/${process.env.ORACLE_PASSWORD || 'Oracle_4U'}@${cfg.database} as sysdba`
    : `${schema}/Restaurant_4U@${cfg.database}`;
  const input = 'set heading off feedback off pagesize 0 linesize 2000 trimspool on define off sqlformat default\n' + statements + '\nexit\n';
  const out = execFileSync('docker', ['exec', '-i', cfg.container, 'sql', '-S', connect], {
    input, encoding: 'utf8', env: { ...process.env, MSYS_NO_PATHCONV: '1' }, maxBuffer: 64 * 1024 * 1024
  });
  return out.replace(/\x1b\[[0-9;]*m/g, '').split(/\r?\n/).map(l => l.trimEnd()).filter(l => l.length);
}

// runs a script file of the repository inside the sandbox
export function sqlFile(schema, repoPath, args = []) {
  const connect = `${schema}/Restaurant_4U@${cfg.database}`;
  return execFileSync('docker', ['exec', '-w', '/repo', '-i', cfg.container, 'sql', '-S', connect, '@' + repoPath, ...args], {
    encoding: 'utf8', env: { ...process.env, MSYS_NO_PATHCONV: '1' }, maxBuffer: 64 * 1024 * 1024
  }).replace(/\x1b\[[0-9;]*m/g, '');
}

// calls a REST service of a schema alias
export async function rest(alias, method, servicePath, { headers = {}, body } = {}) {
  const response = await fetch(`${cfg.ords}/${alias}${servicePath}`, {
    method,
    headers: body !== undefined ? { 'Content-Type': 'application/json', ...headers } : headers,
    body: body !== undefined ? (typeof body === 'string' ? body : JSON.stringify(body)) : undefined
  });
  const text = await response.text();
  let json;
  try { json = JSON.parse(text); } catch (e) { /* not JSON */ }
  return { status: response.status, text, json, headers: response.headers };
}

// ORDS caches some metadata for a moment: repeats a call until it returns the
// expected value or the time is up, and returns the last value
export async function eventually(fn, expected, timeout = 12000) {
  const end = Date.now() + timeout;
  let value = await fn();
  while (value !== expected && Date.now() < end) {
    await new Promise(resolve => setTimeout(resolve, 500));
    value = await fn();
  }
  return value;
}

// ---------------------------------------------------------------- the application
let downloads = 0;

export class App {
  constructor(page, alias) {
    this.page = page;
    this.url = `${cfg.ords}/r/${cfg.workspace}/${alias}/`;
  }

  async login(user = cfg.user, password = cfg.password) {
    await this.page.goto(this.url + 'home');
    await this.page.fill('#P9999_USERNAME', user);
    await this.page.fill('#P9999_PASSWORD', password);
    await this.page.getByRole('button', { name: 'Sign In' }).click();
    await this.page.waitForLoadState('networkidle');
    this.session = new URL(this.page.url()).searchParams.get('session');
  }

  async go(pagePath) {
    await this.page.goto(this.url + pagePath + (pagePath.includes('?') ? '&' : '?') + 'session=' + this.session);
    await this.page.waitForLoadState('networkidle');
  }

  button(name) {
    return this.page.getByRole('button', { name, exact: true });
  }

  // clicks something that leads to a new page
  async nav(target) {
    const locator = typeof target === 'string' ? this.page.locator(target) : target;
    await Promise.all([this.page.waitForNavigation(), locator.first().click()]);
    await this.page.waitForLoadState('networkidle');
  }

  async success() {
    return (await this.page.locator('#APEX_SUCCESS_MESSAGE .t-Alert-title').allInnerTexts()).join(' ').trim();
  }

  // clicks something that is expected to end with an error message on the same page
  async error(target, scope = this.page) {
    const locator = typeof target === 'string' ? scope.locator(target) : target;
    await scope.locator('body').evaluate(() => window.apex.message.clearErrors());
    await locator.first().click();
    await scope.locator('.a-Notification-item').first().waitFor({ timeout: 15000 });
    return (await scope.locator('.a-Notification-item').allInnerTexts()).join(' | ');
  }

  async value(item, scope = this.page) {
    return scope.locator('body').evaluate((body, id) => window.apex.item(id).getValue(), item);
  }

  async set(item, value, scope = this.page) {
    await scope.locator('body').evaluate((body, [id, v]) => window.apex.item(id).setValue(v), [item, value]);
  }

  // the modal dialog page with the given title
  dialog(title) {
    return this.page.frameLocator(`iframe[title="${title}"]`);
  }

  async dialogClosed(title) {
    await this.page.locator(`iframe[title="${title}"]`).waitFor({ state: 'detached', timeout: 20000 });
    await this.page.waitForLoadState('networkidle');
  }

  async confirm() {
    await this.page.locator('.ui-dialog--notification .js-confirmBtn').last().click();
  }

  // opens a page through the navigation menu
  async menu(label) {
    const href = await this.page.evaluate(text => {
      const link = Array.from(document.querySelectorAll('.t-TreeNav a, #t_TreeNav a')).find(a => a.textContent.trim() === text);
      return link ? link.href : null;
    }, label);
    if (!href) {
      throw new Error('no menu entry ' + label);
    }
    await this.page.goto(href);
    await this.page.waitForLoadState('networkidle');
  }

  rows(selector) {
    return this.page.locator(selector).allInnerTexts().then(list => list.map(t => t.replace(/\s+/g, ' ').trim()));
  }

  // ---- code editor
  async editor(item = 'P13_SOURCE') {
    await this.page.waitForFunction(id => !!document.getElementById(id).rstEditor, item, { timeout: 30000 });
  }

  async setSource(text, item = 'P13_SOURCE') {
    await this.editor(item);
    await this.page.evaluate(([id, t]) => document.getElementById(id).rstEditor.editor.setValue(t), [item, text]);
  }

  // waits for the compile check to finish and returns its state and text
  async checkResult() {
    await this.page.waitForFunction(() => {
      const e = document.querySelector('.rst-check');
      return e && !e.classList.contains('is-checking');
    }, null, { timeout: 20000 });
    const element = this.page.locator('.rst-check');
    return {
      state: (await element.getAttribute('class')).replace('rst-check', '').replace('is-', '').trim(),
      text: await element.innerText()
    };
  }

  // waits until a check that was started by a change has come back
  async checkAfterChange() {
    await this.page.waitForTimeout(1300);
    return this.checkResult();
  }

  async download(target) {
    const locator = typeof target === 'string' ? this.page.locator(target) : target;
    const [download] = await Promise.all([this.page.waitForEvent('download', { timeout: 30000 }), locator.first().click()]);
    // several downloads can have the same name, keep each of them
    downloads += 1;
    const file = path.join(cfg.output, String(downloads).padStart(2, '0') + '-' + download.suggestedFilename());
    await download.saveAs(file);
    return { name: download.suggestedFilename(), file, buffer: fs.readFileSync(file), text: fs.readFileSync(file, 'utf8') };
  }
}
