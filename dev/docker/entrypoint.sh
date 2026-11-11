#!/usr/bin/env bash
# Entrypoint of the ORDS + APEX development image.
#   1. waits for the database
#   2. installs APEX when it is missing (or APEX_INSTALL_MODE=force)
#   3. installs the ORDS schema when it is missing
#   4. serves ORDS in standalone mode
set -euo pipefail

: "${DB_HOST:=db}"
: "${DB_PORT:=1521}"
: "${PDB_NAME:=FREEPDB1}"
: "${ORDS_CONFIG:=/etc/ords/config}"
: "${APEX_HTTP_PORT:=8181}"
: "${APEX_IMAGES:=/opt/apex/images}"
: "${APEX_HOME:=/opt/apex}"
: "${APEX_INSTALL_MODE:=auto}"

CONN="sys/${ORACLE_PASSWORD}@${DB_HOST}:${DB_PORT}/${PDB_NAME} as sysdba"
mkdir -p "${ORDS_CONFIG}"

echo "[wait] waiting for ${DB_HOST}:${DB_PORT}/${PDB_NAME} ..."
until printf 'connect %s\nselect 1 from dual;\nexit\n' "${CONN}" | sql -S /nolog >/dev/null 2>&1; do
  sleep 10
done
echo "[wait] database is reachable"

APEX_VER="$(printf 'set heading off\nset feedback off\nconnect %s\nselect version_no from apex_release;\nexit\n' "${CONN}" \
            | sql -S /nolog 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)+' | head -n1 || true)"

if [ "${APEX_INSTALL_MODE}" = "force" ] || [ -z "${APEX_VER}" ]; then
  echo "[apex] installing APEX (current: '${APEX_VER:-none}') - this takes a few minutes ..."
  cd "${APEX_HOME}"
  sql -S /nolog <<SQL
connect ${CONN}
@apexins.sql SYSAUX SYSAUX TEMP /i/
begin
  apex_instance_admin.set_parameter('IMAGE_PREFIX', '/i/');
  commit;
end;
/
alter user apex_public_user identified by "${ORDS_PUBLIC_USER_PASSWORD}" account unlock;
begin
  apex_util.set_security_group_id(10);
  apex_util.create_user(
    p_user_name                    => 'ADMIN',
    p_email_address                => 'admin@example.com',
    p_web_password                 => '${APEX_ADMIN_PASSWORD}',
    p_developer_privs              => 'ADMIN',
    p_change_password_on_first_use => 'N');
  apex_util.set_security_group_id(null);
  commit;
end;
/
exit
SQL
  echo "[apex] APEX installed"
else
  echo "[apex] APEX ${APEX_VER} already installed"
fi

if [ ! -f "${ORDS_CONFIG}/databases/default/pool.xml" ]; then
  echo "[ords] installing ORDS schema ..."
  until printf '%s\n%s\n' "${ORACLE_PASSWORD}" "${ORDS_PUBLIC_USER_PASSWORD}" | \
        ords --config "${ORDS_CONFIG}" install \
          --admin-user SYS \
          --db-hostname "${DB_HOST}" \
          --db-port "${DB_PORT}" \
          --db-servicename "${PDB_NAME}" \
          --gateway-mode proxied \
          --gateway-user APEX_PUBLIC_USER \
          --feature-sdw true \
          --password-stdin ; do
    echo "[ords] retrying in 20s ..."
    sleep 20
  done
  echo "[ords] ORDS schema installed"
else
  echo "[ords] ORDS already configured"
fi

ords --config "${ORDS_CONFIG}" config set standalone.static.path "${APEX_IMAGES}"
ords --config "${ORDS_CONFIG}" config set standalone.http.port  "${APEX_HTTP_PORT}"

echo "[ords] serving on port ${APEX_HTTP_PORT}"
exec ords --config "${ORDS_CONFIG}" serve
