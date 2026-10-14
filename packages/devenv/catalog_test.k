import .catalog

test_ports_bind_loopback_with_overrides = lambda {
  doc = catalog.render("p", {
    nats = {
      ports = {monitor = 18222}
    }
  })
  assert doc.services.nats.ports == ["127.0.0.1:4222:4222", "127.0.0.1:18222:8222"]
}

test_postgres_credentials_default_and_override = lambda {
  plain = catalog.render("p", {
    postgres = {}
  }).services.postgres
  assert plain.environment == {POSTGRES_USER = "dev", POSTGRES_PASSWORD = "dev", POSTGRES_DB = "dev"}
  assert plain.healthcheck.test[1] == "pg_isready -U dev -d dev"
  app = catalog.render("p", {
    postgres = {user = "app", password = "pw"}
  }).services.postgres
  # the database defaults to the user, so a URL needs only one name
  assert app.environment == {POSTGRES_USER = "app", POSTGRES_PASSWORD = "pw", POSTGRES_DB = "app"}
  assert app.healthcheck.test[1] == "pg_isready -U app -d app"
}

test_volumes_only_for_picked_services_that_own_one = lambda {
  doc = catalog.render("p", {postgres = {}, mailpit = {}})
  assert doc.volumes == {
    "postgres-data" = {}
  }
  assert [n for n in doc.services] == ["postgres", "mailpit"]
}

test_every_entry_has_a_healthcheck_and_pinned_image = lambda {
  doc = catalog.render("p", {n = {} for n in catalog.names()})
  bad = [n for n, s in doc.services if len(s.healthcheck.test) == 0 or ":" not in s.image or s.image.endswith(":latest")]
  assert bad == [], "no healthcheck or unpinned image: ${bad}"
}
