import .catalog

# A docker compose document at the root, so `kcl run` output is a compose file:
#
#   kcl run oci://docker.io/yurikrupnik/devenv --tag <v> \
#     -D project=shl-local -D 'services={"postgres": {"ports": {"postgres": 5433}}, "valkey": {}}'
#
# project   compose project name: prefixes the network and the volumes (default devenv)
# services  catalog name -> overrides (`ports` by port name; postgres also takes
#           user, password, database)
_doc = catalog.render(option("project", default="devenv"), option("services", default={}))

name = _doc.name
services = _doc.services
volumes = _doc.volumes
