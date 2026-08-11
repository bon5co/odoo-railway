# Odoo 19.0 wrapper for Railway.
#
# The wrapper exists because everything that makes a stock Odoo container safe
# lives in odoo.conf, not in the environment: Odoo has no env-var configuration
# layer at all, so `admin_passwd`, `list_db`, `dbfilter` and `proxy_mode` cannot
# be set by a Railway template variable. A published listing that ships an
# ADMIN_PASSWD variable is setting a variable nothing reads -- verified against
# this image, where the master password stays at its compiled-in default.
#
# The literals below are baked rather than published as template variables,
# because templateGenerate drops a literal defaultValue and the variable then
# publishes as a blank required field.
FROM odoo:19.0@sha256:94a4f480b8039dc9ca2bca9e77e59f97d3311f66e2aad663cf2670be9c66d4ea

USER root

ENV ODOO_DB_NAME=odoo \
    ODOO_ADMIN_LOGIN=admin \
    ODOO_DATA_DIR=/var/lib/odoo

COPY seed_admin.py /opt/railway/seed_admin.py
COPY railway-entrypoint.sh /usr/local/bin/railway-entrypoint.sh
RUN chmod +x /usr/local/bin/railway-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/railway-entrypoint.sh"]
CMD []
