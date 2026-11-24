# Entry point outside Crossplane — Pulumi's @org/landing-zone validates its
# input here before tier 0 creates anything:
#
#   kcl run main.k -D specFile=<spec.json> --format json
#
# prints {"spec": <the spec with every XRD default applied>}, or fails with the
# first rule it breaks. Without specFile it validates the azure example.
import json
import file
import .contract
import .example

_file = option("specFile")
spec = contract.validate(json.decode(file.read(_file)) if _file else example.azure)
