# Backing services for a developer's machine, as docker compose services.
#
# Each entry is one compose service with a pinned image, ports published on
# 127.0.0.1 only, a healthcheck (so `docker compose up --wait` returns once the
# service answers) and a named volume for its data. A profile picks entries and
# overrides what differs per app: host ports, and credentials where the image
# takes them. Credentials here are throwaway dev values on loopback, not secrets.
schema Healthcheck:
  test: [str]
  interval: str = "2s"
  timeout: str = "2s"
  retries: int = 60

schema Service:
  """One compose service. `$ports` maps a port's name to its container port."""
  image: str
  command?: [str]
  environment?: {str:str}
  ports: [str] = []
  volumes: [str] = []
  healthcheck: Healthcheck
  restart: "no" | "unless-stopped" = "unless-stopped"

schema Entry:
  """A catalog entry: the service, its container ports by name, and the volume it owns."""
  service: Service
  container_ports: {str:int}
  volume?: str

schema Overrides:
  """What a profile may change: host ports by port name, and an entry's own settings."""
  ports?: {str:int}
  user?: str
  password?: str
  database?: str

# Ports published on loopback only: `127.0.0.1:<host>:<container>`.
publish = lambda container_ports: {str:int}, host_ports: {str:int} -> [str] {
  ["127.0.0.1:${host_ports[name] if name in host_ports else port}:${port}" for name, port in container_ports]
}

postgres = lambda o: Overrides -> Entry {
  _user = o.user or "dev"
  _db = o.database or _user
  Entry {
    container_ports = {postgres = 5432}
    volume = "postgres-data"
    service = Service {
      image = "postgres:17.6"
      environment = {
        POSTGRES_USER = _user
        POSTGRES_PASSWORD = o.password or "dev"
        POSTGRES_DB = _db
      }
      volumes = ["postgres-data:/var/lib/postgresql/data"]
      healthcheck = Healthcheck {test = ["CMD-SHELL", "pg_isready -U ${_user} -d ${_db}"]}
    }
  }
}

valkey = lambda o: Overrides -> Entry {
  Entry {
    container_ports = {valkey = 6379}
    volume = "valkey-data"
    service = Service {
      image = "valkey/valkey:8.1"
      volumes = ["valkey-data:/data"]
      healthcheck = Healthcheck {test = ["CMD", "valkey-cli", "ping"]}
    }
  }
}

nats = lambda o: Overrides -> Entry {
  Entry {
    container_ports = {client = 4222, monitor = 8222}
    volume = "nats-data"
    service = Service {
      # alpine: the default image has no shell or wget for the healthcheck
      image = "nats:2.11-alpine"
      command = ["--jetstream", "--store_dir", "/data", "--http_port", "8222"]
      volumes = ["nats-data:/data"]
      healthcheck = Healthcheck {test = ["CMD", "wget", "-q", "--spider", "http://127.0.0.1:8222/healthz"]}
    }
  }
}

mailpit = lambda o: Overrides -> Entry {
  Entry {
    container_ports = {smtp = 1025, ui = 8025}
    service = Service {
      image = "axllent/mailpit:v1.27"
      healthcheck = Healthcheck {test = ["CMD", "/mailpit", "readyz"]}
    }
  }
}

# OTel Collector, Prometheus, Loki, Tempo and Grafana in one container.
otel_lgtm = lambda o: Overrides -> Entry {
  Entry {
    container_ports = {grafana = 3000, otlp_grpc = 4317, otlp_http = 4318, prometheus = 9090}
    volume = "otel-lgtm-data"
    service = Service {
      image = "grafana/otel-lgtm:0.34.0"
      volumes = ["otel-lgtm-data:/data"]
      healthcheck = Healthcheck {test = ["CMD", "test", "-f", "/tmp/ready"], interval = "5s"}
    }
  }
}

# Private, so `kcl run` on the package root does not print it next to the compose keys.
_CATALOG = {
  postgres = postgres
  valkey = valkey
  nats = nats
  mailpit = mailpit
  "otel-lgtm" = otel_lgtm
}

# Every catalog name.
names = lambda -> [str] {
  [n for n in _CATALOG]
}

# The compose document for the picked services. `picked` maps a catalog name to
# its overrides ({} for none); an unknown name fails the render and lists the
# catalog.
render = lambda project: str, picked: {str:} -> {str:} {
  _unknown = [n for n in picked if n not in _CATALOG]
  assert len(_unknown) == 0, "unknown services ${_unknown}; the catalog has ${names()}"
  assert project != "", "project must be set: it names the compose project, its network and volumes"
  _entries = {n = _CATALOG[n](Overrides {**(picked[n] or {})}) for n in picked}
  {
    name = project
    services = {n = e.service | {ports = publish(e.container_ports, (picked[n] or {}).ports or {})} for n, e in _entries}
    volumes = {e.volume = {} for _, e in _entries if e.volume}
  }
}
