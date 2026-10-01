# regions — the location catalog: logical location id -> the backend region in
# that jurisdiction.
#
# Rule: a location maps to a region in the SAME COUNTRY on every backend, or to
# nothing. "Closest" is not good enough — residency is a legal boundary, not a
# latency one — so a backend without a region in that country has no entry and
# the render fails until the Residency names a region explicitly. Today that is
# nl on aws (AWS has no Dutch region; Frankfurt or Ireland would move the data
# to another country).
#
# openbao is not a column: it has no regions (keys live in the cluster's
# OpenBao), so every location resolves to `in_cluster` there.
in_cluster = "in-cluster"

catalog: {str:{str:str}} = {
    "il" = {
        jurisdiction = "Israel"
        aws = "il-central-1" # Tel Aviv
        gcp = "me-west1" # Tel Aviv
        azure = "israelcentral"
        oci = "il-jerusalem-1" # Jerusalem
    }
    "de" = {
        jurisdiction = "Germany"
        aws = "eu-central-1" # Frankfurt
        gcp = "europe-west3" # Frankfurt
        azure = "germanywestcentral" # Frankfurt
        oci = "eu-frankfurt-1"
    }
    "nl" = {
        jurisdiction = "Netherlands"
        gcp = "europe-west4" # Eemshaven
        azure = "westeurope" # Amsterdam
        oci = "eu-amsterdam-1"
    }
    "gb" = {
        jurisdiction = "United Kingdom"
        aws = "eu-west-2" # London
        gcp = "europe-west2" # London
        azure = "uksouth" # London
        oci = "uk-london-1"
    }
    "us-va" = {
        jurisdiction = "United States (Virginia)"
        aws = "us-east-1" # N. Virginia
        gcp = "us-east4" # Ashburn
        azure = "eastus" # Virginia
        oci = "us-ashburn-1"
    }
}

# jurisdiction(location) — the catalog country, or "" for an id outside it.
jurisdiction = lambda location: str -> str {
    catalog[location].jurisdiction if location in catalog else ""
}

# resolve(location, provider) — the backend region for one location entry
# ({name, region?}). An explicit region always wins: it is how a Residency
# covers an id outside the catalog, or deliberately crosses a border the
# catalog refuses to cross. Fails the render, never guesses.
resolve = lambda loc: {str:any}, provider: str -> str {
    _name = loc.name
    _explicit = loc?.region or ""
    _entry = catalog[_name] if _name in catalog else {}
    _mapped = _entry[provider] if provider in _entry else ""
    assert provider == "openbao" or _explicit or _mapped, "residency: location ${_name} has no ${provider} region in the catalog; set spec.locations[${_name}].region explicitly"
    in_cluster if provider == "openbao" else (_explicit or _mapped)
}
