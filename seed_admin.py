# Run through `odoo shell`. Sets the administrator password and freezes the
# public base URL, then commits.
#
# Odoo initialises a fresh database with the administrator login "admin" and the
# password "admin". Nothing in the image changes that, and no environment
# variable exists to change it either, so on a stock deploy the first stranger
# who opens the public URL logs in with the documented default and owns the
# instance (uid 2, is_admin true -- reproduced against two published Railway
# listings on 2026-08-11).
#
# This runs on EVERY boot, not just the first, so the password rotates by
# redeploy. Upstream has no path that does this: `createsuperuser`-style helpers
# do not exist and the UI change-password flow needs the old password.
import os

login = os.environ.get("ODOO_ADMIN_LOGIN") or "admin"
password = os.environ["ODOO_ADMIN_PASSWORD"]
domain = os.environ.get("RAILWAY_PUBLIC_DOMAIN") or ""

admin = env.ref("base.user_admin", raise_if_not_found=False)  # noqa: F821
if admin is None:
    admin = env["res.users"].browse(2)  # noqa: F821

values = {"password": password}
if admin.login != login:
    values["login"] = login
admin.sudo().write(values)
print("[seed] administrator login=%s password set" % admin.login)

if domain:
    base = "https://%s" % domain
    params = env["ir.config_parameter"].sudo()  # noqa: F821
    params.set_param("web.base.url", base)
    # Without the freeze Odoo rewrites web.base.url to whatever Host header the
    # next logged-in request carried, so one visit through a stale domain
    # repoints every emailed link and password-reset URL.
    params.set_param("web.base.url.freeze", "True")
    print("[seed] web.base.url=%s (frozen)" % base)

env.cr.commit()  # noqa: F821
