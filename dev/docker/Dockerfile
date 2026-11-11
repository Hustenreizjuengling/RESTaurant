# Self-contained ORDS + APEX image for local development and testing.
# The APEX release is selected with the APEX_URL build argument.
FROM eclipse-temurin:21-jre

ARG ORDS_URL=https://download.oracle.com/otn_software/java/ords/ords-latest.zip
ARG SQLCL_URL=https://download.oracle.com/otn_software/java/sqldeveloper/sqlcl-latest.zip
ARG APEX_URL=https://download.oracle.com/otn_software/apex/apex_26.2.zip

RUN apt-get update \
 && apt-get install -y --no-install-recommends unzip curl ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /opt/ords /tmp/dl \
 && curl -fsSL "${ORDS_URL}"  -o /tmp/dl/ords.zip  && unzip -q /tmp/dl/ords.zip  -d /opt/ords \
 && curl -fsSL "${SQLCL_URL}" -o /tmp/dl/sqlcl.zip && unzip -q /tmp/dl/sqlcl.zip -d /opt \
 && curl -fsSL "${APEX_URL}"  -o /tmp/dl/apex.zip  && unzip -q /tmp/dl/apex.zip  -d /opt \
 && rm -rf /tmp/dl

ENV PATH=/opt/ords/bin:/opt/sqlcl/bin:${PATH} \
    ORDS_CONFIG=/etc/ords/config \
    APEX_HOME=/opt/apex \
    APEX_IMAGES=/opt/apex/images

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN sed -i 's/\r$//' /usr/local/bin/entrypoint.sh && chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 8181
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
