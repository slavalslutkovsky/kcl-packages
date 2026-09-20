"""
pricing/rates — the committed multi-cloud rate card.

PUBLIC, ON-DEMAND, PRE-DISCOUNT LIST PRICES in USD. Nothing here knows about
your EDP, your committed-use discounts, your free tier or your credits, and
nothing here is a quote. The card exists so the portable size ladders can be
COMPARED across clouds before anything is provisioned; the invoice is the
authority afterwards.

WHERE THE NUMBERS COME FROM — TWO TIERS, AND THE DIFFERENCE MATTERS

The card is NOT uniformly machine-generated, and claiming otherwise would be
the first lie in it.

  aws, azure   MACHINE-FETCHED by `tools/pricing/src/refresh-rates.ts`
               (`just price-refresh aws azure`) from the AWS Price List Query
               API and the Azure Retail Prices API. Every cell in those two
               blocks was written by the generator, and `just price-check aws
               azure` re-fetches and fails on any drift. The azure half needs
               no credentials at all, so anyone can verify it in seconds.

  gcp          HAND-ENTERED from the public pricing pages cited above each
               table. The GCP Cloud Billing Catalog API rejects
               unauthenticated callers outright and this repo holds no
               GOOGLE_API_KEY, so the block could not be machine-fetched.
               `just price-check gcp` therefore CANNOT verify it: without a
               key it exits non-zero naming GOOGLE_API_KEY rather than
               pretending the numbers passed. The generator's gcp path is
               written and wired, but has never executed — see docs/pricing.md.

Both tiers carry an `as_of` date, the exact query or page the number came
from, and the arithmetic of any derived cell. Hand-editing a number in the
aws or azure block is how a rate card starts lying: change the generator, or
fix the vendor query, and re-run it.

The generator refreshes ONE CLOUD AT A TIME, splicing between the
`# >>> GENERATED <cloud>` / `# <<< END <cloud>` markers, precisely because
the three APIs do not have the same reachability. Whole-file regeneration
would mean no block could be refreshed unless all three were reachable at
once — which, today, they never are.

DERIVED CELLS

Two kinds of cell are arithmetic rather than a single fetched SKU, because
that is genuinely how the vendor bills:

  * a `$/GB-month` storage rate whose SKU is published per GiB-HOUR is
    `hourly * 730`, rounded to 5 decimals (GCP publishes the hourly figure and
    the monthly one; the round trips exactly);
  * a managed-Postgres `$/hour` whose vendor prices COMPONENTS rather than
    instances (GCP bills vCPU + memory, Azure bills General Purpose per
    vCore) is the component rate times the shape encoded in the SKU name.

The arithmetic is written next to every such number, so the cell is
checkable against a public page without running anything.

WHAT IS NOT PRICED — see docs/pricing.md for the full list and why:
network egress, IOPS/throughput, snapshots, backups, per-request API charges,
support plans, the in-cluster backends (kubevirt, cnpg, valkey, rustfs,
onprem — a self-hosted backend has no vendor list price), and cluster NODE
root disks (the KubernetesCluster XRD exposes no disk field, so each backend
takes a different cloud default).

This module is DATA ONLY: no imports, no schemas, no logic. `lib.k` puts the
types and the lookups on top of it, which is also what keeps the generator's
job a pure text splice.
"""

# One logical region, spelled three ways. The comparison is only honest when
# each cloud is quoted in a region that means the same thing — same continent,
# same "cheapest large US region" role, all three vendors' primary/default.
# Adding a set means adding its three regions to all three blocks below;
# `pricing_test.k` fails until every rate a ladder can produce exists in each.
region_sets = {
    us = {aws = "us-east-1", gcp = "us-central1", azure = "eastus"}
}

# The hour count every monthly figure in this repo uses. 730 = 8760 / 12, the
# convention all three vendors' own calculators use for a "month"; it is NOT
# 720 and NOT the length of the current month.
hours_per_month = 730

# >>> GENERATED aws — tools/pricing/src/refresh-rates.ts, do not hand-edit.
# fetched 2026-09-19 from the AWS Price List Query API
#   (POST https://api.pricing.us-east-1.amazonaws.com/ AWSPriceListService.GetProducts,
#    SigV4-signed; needs AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY).
as_of_aws = "2026-09-19"

aws = {
    # EC2 Compute Instance, Linux, Shared tenancy, no pre-installed software,
    # capacitystatus=Used, "No License required".
    # https://aws.amazon.com/ec2/pricing/on-demand/
    compute_hour = {
        "us-east-1" = {
            "t3.medium" = 0.0416
            "m5.large" = 0.096
            "m5.xlarge" = 0.192
            "m5.2xlarge" = 0.384
        }
    }
    # EKS cluster hour, usagetype USE1-AmazonEKS-Hours:perCluster. Charged per
    # cluster whatever its size. https://aws.amazon.com/eks/pricing/
    control_plane = {
        "us-east-1" = {sku = "EKS cluster", usd_hour = 0.1}
    }
    # EBS gp3 provisioned storage. The vm/aws backend sets only
    # rootBlockDevice.volumeSize, so the provider default volume type (gp3)
    # applies. The 3000 baseline IOPS and 125 MB/s are free; provisioned
    # extras are not priced here. https://aws.amazon.com/ebs/pricing/
    root_disk = {
        "us-east-1" = {sku = "EBS gp3", gb_month = 0.08}
    }
    # RDS Database Instance, PostgreSQL, Single-AZ, "No license required".
    # https://aws.amazon.com/rds/postgresql/pricing/
    db_instance_hour = {
        "us-east-1" = {
            "db.t4g.micro" = 0.016
            "db.t4g.small" = 0.032
            "db.t4g.medium" = 0.065
            "db.t4g.large" = 0.129
            "db.m7g.xlarge" = 0.337
            "db.m7g.2xlarge" = 0.674
            "db.m7g.4xlarge" = 1.348
            "db.m7g.8xlarge" = 2.696
        }
    }
    # RDS General Purpose-GP3 storage, PostgreSQL, Single-AZ.
    db_storage = {
        "us-east-1" = {sku = "RDS gp3 storage", gb_month = 0.115}
    }
    # S3 Standard, TimedStorage-ByteHrs, the first 50 TB tier (beginRange 0).
    # Volume tiers above 50 TB are cheaper and are NOT modelled: an estate big
    # enough to reach them is negotiating a private rate anyway.
    # https://aws.amazon.com/s3/pricing/
    object = {
        "us-east-1" = {sku = "S3 Standard", gb_month = 0.023}
    }
}

# <<< END aws

# >>> GENERATED gcp — the splice target once a GOOGLE_API_KEY exists; the one
# block the marker does not yet describe. Not generated, but
# hand-entered 2026-09-19 from the public pricing pages cited per table,
# because the GCP Cloud Billing Catalog API rejects unauthenticated callers
# and this repo holds no GOOGLE_API_KEY (`just secrets-check` refuses
# credential files, and none is in the environment). `just price-refresh gcp`
# machine-verifies this whole block once a key exists; without one it fails
# loudly naming the variable rather than writing a guess.
as_of_gcp = "2026-09-19"

gcp = {
    # Compute Engine on-demand ("Default") price, Iowa (us-central1).
    # e2-medium is a shared-core type and sits in its own table.
    # https://cloud.google.com/products/compute/pricing/general-purpose#e2-machine-types
    compute_hour = {
        "us-central1" = {
            "e2-medium" = 0.03350571
            "e2-standard-2" = 0.06701142
            "e2-standard-4" = 0.13402284
            "e2-standard-8" = 0.26804568
        }
    }
    # Flat GKE cluster management fee, identical in every region and for every
    # topology (zonal, regional, Autopilot). The one-free-zonal-cluster credit
    # is an account-level free tier and is deliberately not modelled.
    # https://cloud.google.com/kubernetes-engine/pricing#cluster_management_fee
    control_plane = {
        "us-central1" = {sku = "GKE cluster management fee", usd_hour = 0.1}
    }
    # Persistent Disk "Standard provisioned space", us-central1:
    # $0.000054795/GiB-hour * 730 = 0.04. pd-standard because the vm/gcp
    # backend sets bootDisk.initializeParams without a `type`, and the
    # Terraform-derived provider defaults that to pd-standard. The first 30
    # GiB/month per account is free and is not modelled.
    # https://cloud.google.com/compute/disks-image-pricing#persistentdisk
    root_disk = {
        "us-central1" = {sku = "PD Standard (pd-standard)", gb_month = 0.04}
    }
    # Cloud SQL Enterprise edition, General Purpose machine series, Iowa:
    # vCPU $0.0413/hour and memory $0.007/GiB-hour. A db-custom-<vCPU>-<MiB>
    # tier is billed as those two components, so each cell below is
    # vCPU * 0.0413 + (MiB / 1024) * 0.007 — the arithmetic is in the comment
    # so the cell can be checked against the page without running anything.
    # https://cloud.google.com/sql/pricing#pg-instance-pricing
    db_instance_hour = {
        "us-central1" = {
            # 1 * 0.0413 + 3.75 * 0.007
            "db-custom-1-3840" = 0.06755
            # 2 * 0.0413 + 7.5 * 0.007
            "db-custom-2-7680" = 0.1351
            # 4 * 0.0413 + 15 * 0.007
            "db-custom-4-15360" = 0.2702
            # 8 * 0.0413 + 30 * 0.007
            "db-custom-8-30720" = 0.5404
            # 16 * 0.0413 + 60 * 0.007
            "db-custom-16-61440" = 1.0808
        }
    }
    # Cloud SQL SSD storage capacity, non-HA: $0.000232877/GiB-hour * 730.
    # CAVEAT, the weakest cell in the card: unlike the compute tables, the
    # storage table on that page carries no region selector, so us-central1 is
    # inferred from the section it sits in rather than read off a label. It is
    # almost certainly right — the round trip lands exactly on Google's
    # published $0.170/GB-month — but it is the one number here that a
    # GOOGLE_API_KEY should be pointed at first.
    db_storage = {
        "us-central1" = {sku = "Cloud SQL SSD storage", gb_month = 0.17}
    }
    # Cloud Storage Standard, regional us-central1:
    # $0.000027397/GiB-hour * 730. Dual-region and multi-region buckets cost
    # more and are a different `location`, so they are a different rate.
    # https://cloud.google.com/storage/pricing#storage-pricing
    object = {
        "us-central1" = {sku = "Cloud Storage Standard (regional)", gb_month = 0.02}
    }
}

# <<< END gcp

# >>> GENERATED azure — tools/pricing/src/refresh-rates.ts, do not hand-edit.
# fetched 2026-09-19 from the Azure Retail Prices API
#   (GET https://prices.azure.com/api/retail/prices?currencyCode='USD'&$filter=...,
#    anonymous — no credentials of any kind).
as_of_azure = "2026-09-19"

azure = {
    # Virtual Machines, Consumption, eastus, Linux (the Windows meters carry
    # the licence and are excluded by productName, Spot and Low Priority by
    # meterName).
    # https://azure.microsoft.com/pricing/details/virtual-machines/linux/
    compute_hour = {
        "eastus" = {
            "Standard_B2s" = 0.0416
            "Standard_D2s_v5" = 0.096
            "Standard_D4s_v5" = 0.192
            "Standard_D8s_v5" = 0.384
        }
    }
    # AKS: the cluster/azure backend leaves skuTier unset, so the cluster runs
    # on the FREE tier — a real $0 control plane with no uptime SLA, not a
    # missing rate. The Standard tier (meter "Standard Uptime SLA") is
    # $0.1/hour in eastus; switch this cell to it the day the backend
    # starts setting skuTier: Standard. `lib.k` attaches a note to every Azure
    # cluster estimate so the zero never reads as a bug.
    # https://azure.microsoft.com/pricing/details/kubernetes-service/
    control_plane = {
        "eastus" = {sku = "AKS Free tier", usd_hour = 0}
    }
    # Standard HDD managed disks (Standard_LRS), eastus — what the vm/azure
    # backend asks for in osDisk.storageAccountType. Azure bills a managed
    # disk by PROVISIONED TIER, not by the gigabyte, so this is the S-tier
    # ladder and the price of a 40 GiB disk is the price of an S6 (64 GiB).
    # Tier -> size comes from the Azure managed-disk docs; the price of each
    # is the "<tier> LRS Disk" meter at 1/Month.
    # https://azure.microsoft.com/pricing/details/managed-disks/
    root_disk = {
        "eastus" = {
            sku = "Managed Disk Standard_LRS"
            tiers = [
                # S4
                {gb = 32, usd_month = 1.536}
                # S6
                {gb = 64, usd_month = 3.008}
                # S10
                {gb = 128, usd_month = 5.888}
                # S15
                {gb = 256, usd_month = 11.328}
                # S20
                {gb = 512, usd_month = 21.76}
                # S30
                {gb = 1024, usd_month = 40.96}
                # S40
                {gb = 2048, usd_month = 77.824}
                # S50
                {gb = 4096, usd_month = 143.36}
                # S60
                {gb = 8192, usd_month = 262.14}
                # S70
                {gb = 16384, usd_month = 491.52}
                # S80
                {gb = 32767, usd_month = 953.55}
            ]
        }
    }
    # Azure Database for PostgreSQL Flexible Server compute, eastus. Two
    # billing shapes, both real: Burstable is metered per INSTANCE, General
    # Purpose Dsv3 per vCORE, so the GP cells are vCores times that meter.
    # https://azure.microsoft.com/pricing/details/postgresql/flexible-server/
    db_instance_hour = {
        "eastus" = {
            # meter "B1MS", per instance
            "B_Standard_B1ms" = 0.017
            # meter "B2S", per instance
            "B_Standard_B2s" = 0.068
            # 2 * 0.0855
            "GP_Standard_D2s_v3" = 0.171
            # 4 * 0.0855
            "GP_Standard_D4s_v3" = 0.342
            # 8 * 0.0855
            "GP_Standard_D8s_v3" = 0.684
            # 16 * 0.0855
            "GP_Standard_D16s_v3" = 1.368
        }
    }
    # Flexible Server storage ("Storage Data Stored"). Azure rounds a request
    # up to a fixed step (postgres/azure storage_mb_for), so the billed size
    # is usually larger than the one asked for; lib.k prices the rounded size.
    db_storage = {
        "eastus" = {sku = "Flexible Server storage", gb_month = 0.115}
    }
    # Blob Storage, General Block Blob v2, Hot LRS Data Stored, first tier
    # (tierMinimumUnits 0). https://azure.microsoft.com/pricing/details/storage/blobs/
    object = {
        "eastus" = {sku = "Blob Hot LRS", gb_month = 0.0208}
    }
}

# <<< END azure

# The three blocks above, keyed the way `lib.k` looks them up. Kept as one
# dict rather than three `if cloud == ...` branches so that adding a cloud is
# a data change: a new block, a new entry here, a new spelling in every
# region_sets row, and the drift test tells you what is still missing.
card = {aws = aws, gcp = gcp, azure = azure}

as_of = {aws = as_of_aws, gcp = as_of_gcp, azure = as_of_azure}

# Every cloud the card claims to cover. `lib.compare` defaults to this, and a
# values file naming a cloud outside it fails rather than silently comparing
# two of the three.
clouds = ["aws", "gcp", "azure"]
