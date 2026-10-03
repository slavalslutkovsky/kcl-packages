/**
 * refresh-rates.ts — regenerate the committed rate card from the vendors' own
 * pricing APIs.
 *
 *   node tools/pricing/src/refresh-rates.ts                  refresh every cloud
 *   node tools/pricing/src/refresh-rates.ts aws azure        refresh some
 *   node tools/pricing/src/refresh-rates.ts --check          fail on drift
 *
 * It rewrites ONE BLOCK PER CLOUD inside packages/platform/pricing/rates.k,
 * between the `# >>> GENERATED <cloud>` and `# <<< END <cloud>` markers. Per
 * cloud rather than whole-file because the three APIs do not have the same
 * reachability:
 *
 *   azure  ANONYMOUS. The Retail Prices API needs no credentials at all.
 *   aws    AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY (or AWS_SECRET_KEY).
 *          The Price List Query API is SigV4-signed and GetProducts is free,
 *          but it is still an authenticated call.
 *   gcp    GOOGLE_API_KEY. The Cloud Billing Catalog API rejects
 *          unauthenticated callers outright ("Method doesn't allow
 *          unregistered callers"), and there is no anonymous mirror. Without
 *          a key this exits non-zero naming the variable; it never guesses.
 *
 * WHAT IT FETCHES is not hardcoded here. The list of machine types, RDS
 * classes, Cloud SQL tiers and Flexible Server SKUs comes from the size
 * ladders themselves, read back out of KCL:
 *
 *   kcl run packages/platform/pricing -D skus=true -q
 *
 * so adding a rung to a backend is picked up on the next refresh instead of
 * needing a second list in TypeScript that would rot.
 *
 * EVERY LOOKUP IS EXACT-MATCH-OR-THROW. A vendor query that returns zero
 * products, more than one product, or more than one candidate price
 * dimension is an error naming the cell, never a number chosen by position.
 * Writing a wrong price is strictly worse than writing none.
 */

import { execFileSync } from "node:child_process";
import { createHash, createHmac } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { relative, resolve } from "node:path";

const root = resolve(import.meta.dirname, "../../..");
const ratesPath = resolve(root, "packages/platform/pricing/rates.k");
const pkg = "packages/platform/pricing";

const CLOUDS = ["aws", "gcp", "azure"] as const;
type Cloud = (typeof CLOUDS)[number];

/** How old a block may be before `--check` calls it stale. See docs/pricing.md. */
const STALENESS_DAYS = 90;

/** 8760 / 12 — the same month `packages/platform/pricing/rates.k` uses. */
const HOURS_PER_MONTH = 730;

type Inventory = { cloud: Cloud; region: string; compute: string[]; db: string[] };

// ── helpers ──────────────────────────────────────────────────────────────────

function fail(message: string): never {
  console.error(`refresh-rates: ${message}`);
  process.exit(1);
}

/** The one place a fetched number becomes text, so every cell rounds alike. */
function usd(n: number, places = 8): string {
  const rounded = Number(n.toFixed(places));
  return Number.isInteger(rounded) ? `${rounded}.0` : `${rounded}`;
}

/**
 * A per-GiB-HOUR SKU expressed the way the card wants it. Google publishes
 * both figures and the round trip is exact at five decimals, which is why the
 * card carries 0.04 rather than 0.04000035.
 */
function gbMonthFromHour(perGibHour: number): number {
  return Number((perGibHour * HOURS_PER_MONTH).toFixed(5));
}

/** One date for the whole run, so blocks refreshed together carry the same as_of. */
const TODAY = new Date().toISOString().slice(0, 10);

/** Exactly one, or a named error. Used on every vendor lookup in this file. */
function only<T>(xs: T[], what: string): T {
  if (xs.length === 1) return xs[0]!;
  fail(
    xs.length === 0
      ? `no pricing SKU matched ${what}. The vendor renamed or retired it; fix the query rather than hand-editing the card.`
      : `${xs.length} pricing SKUs matched ${what}, so the right one cannot be chosen by position. Narrow the query.`,
  );
}

// ── the inventory, read back out of the size ladders ─────────────────────────

function inventory(): Record<Cloud, Inventory> {
  let out: string;
  try {
    out = execFileSync("kcl", ["run", pkg, "-D", "skus=true", "-q", "--format", "json"], { cwd: root, encoding: "utf8" });
  } catch (e) {
    fail(`could not read the SKU inventory (\`kcl run ${pkg} -D skus=true -q\`): ${(e as Error).message}`);
  }
  // `--format json` prints one object per document, comma-separated but not
  // bracketed, so it becomes an array with two characters and no YAML parser.
  const docs = JSON.parse(`[${out.trim().replace(/,$/, "")}]`) as Inventory[];
  const byCloud = Object.fromEntries(docs.map((d) => [d.cloud, d])) as Record<Cloud, Inventory | undefined>;
  for (const c of CLOUDS) {
    const inv = byCloud[c];
    if (!inv?.compute?.length || !inv?.db?.length) fail(`the SKU inventory has no ${c} entry — is rates.k's region_sets missing ${c}?`);
  }
  return byCloud as Record<Cloud, Inventory>;
}

// ── AWS: Price List Query API (SigV4) ────────────────────────────────────────

type AwsProduct = {
  product: { productFamily: string; attributes: Record<string, string> };
  terms: { OnDemand: Record<string, { priceDimensions: Record<string, AwsDimension> }> };
};
type AwsDimension = { unit: string; beginRange: string; endRange: string; description: string; pricePerUnit: { USD: string } };

function sigv4(body: string): { host: string; headers: Record<string, string> } {
  const accessKey = process.env.AWS_ACCESS_KEY_ID;
  const secretKey = process.env.AWS_SECRET_ACCESS_KEY ?? process.env.AWS_SECRET_KEY;
  if (!accessKey || !secretKey) {
    fail(
      "the AWS Price List Query API is SigV4-signed and no credentials are set. Export AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY (GetProducts is free and needs only pricing:GetProducts), or run `just price-refresh azure` which needs none.",
    );
  }
  const region = "us-east-1"; // the Price List API itself only lives in us-east-1 and ap-south-1
  const service = "pricing";
  const target = "AWSPriceListService.GetProducts";
  const host = `api.pricing.${region}.amazonaws.com`;
  const amzDate = new Date().toISOString().replace(/[:-]|\.\d{3}/g, "");
  const dateStamp = amzDate.slice(0, 8);
  const payloadHash = createHash("sha256").update(body).digest("hex");
  const canonicalHeaders = `content-type:application/x-amz-json-1.1\nhost:${host}\nx-amz-date:${amzDate}\nx-amz-target:${target}\n`;
  const signedHeaders = "content-type;host;x-amz-date;x-amz-target";
  const canonicalRequest = `POST\n/\n\n${canonicalHeaders}\n${signedHeaders}\n${payloadHash}`;
  const scope = `${dateStamp}/${region}/${service}/aws4_request`;
  const toSign = `AWS4-HMAC-SHA256\n${amzDate}\n${scope}\n${createHash("sha256").update(canonicalRequest).digest("hex")}`;
  let key = createHmac("sha256", `AWS4${secretKey}`).update(dateStamp).digest();
  for (const part of [region, service, "aws4_request"]) key = createHmac("sha256", key).update(part).digest();
  const signature = createHmac("sha256", key).update(toSign).digest("hex");
  return {
    host,
    headers: {
      "content-type": "application/x-amz-json-1.1",
      "x-amz-date": amzDate,
      "x-amz-target": target,
      authorization: `AWS4-HMAC-SHA256 Credential=${accessKey}/${scope}, SignedHeaders=${signedHeaders}, Signature=${signature}`,
    },
  };
}

async function awsProducts(serviceCode: string, filters: Record<string, string>): Promise<AwsProduct[]> {
  const out: AwsProduct[] = [];
  let token: string | undefined;
  do {
    const body = JSON.stringify({
      ServiceCode: serviceCode,
      Filters: Object.entries(filters).map(([Field, Value]) => ({ Type: "TERM_MATCH", Field, Value })),
      MaxResults: 100,
      ...(token ? { NextToken: token } : {}),
    });
    const { host, headers } = sigv4(body);
    const res = await fetch(`https://${host}/`, { method: "POST", headers, body });
    if (!res.ok) fail(`AWS Price List API ${res.status} for ${serviceCode} ${JSON.stringify(filters)}: ${await res.text()}`);
    const json = (await res.json()) as { PriceList: string[]; NextToken?: string };
    out.push(...json.PriceList.map((s) => JSON.parse(s) as AwsProduct));
    token = json.NextToken;
  } while (token);
  return out;
}

function awsDimensions(products: AwsProduct[]): AwsDimension[] {
  return products.flatMap((p) => Object.values(p.terms.OnDemand).flatMap((t) => Object.values(t.priceDimensions)));
}

/** One product, one on-demand dimension, one price. Anything else throws. */
async function awsFlat(serviceCode: string, filters: Record<string, string>, what: string): Promise<number> {
  const dims = awsDimensions(await awsProducts(serviceCode, filters));
  return Number(only(dims, what).pricePerUnit.USD);
}

async function buildAws(inv: Inventory): Promise<string> {
  const region = inv.region;
  const compute: [string, number][] = [];
  for (const machine of inv.compute) {
    compute.push([
      machine,
      await awsFlat(
        "AmazonEC2",
        {
          instanceType: machine,
          regionCode: region,
          operatingSystem: "Linux",
          tenancy: "Shared",
          preInstalledSw: "NA",
          capacitystatus: "Used",
          licenseModel: "No License required",
        },
        `EC2 ${machine} (Linux/Shared) in ${region}`,
      ),
    ]);
  }

  const db: [string, number][] = [];
  for (const cls of inv.db) {
    db.push([
      cls,
      await awsFlat(
        "AmazonRDS",
        { instanceType: cls, regionCode: region, databaseEngine: "PostgreSQL", deploymentOption: "Single-AZ", licenseModel: "No license required" },
        `RDS ${cls} (PostgreSQL/Single-AZ) in ${region}`,
      ),
    ]);
  }

  // The EKS cluster fee shares its tiertype with the Outposts local-cluster
  // SKU, so the region's own dimension is selected by description.
  const eksDims = awsDimensions(await awsProducts("AmazonEKS", { regionCode: region, tiertype: "HAStandard", operation: "CreateOperation" }));
  const eks = Number(only(eksDims.filter((d) => /^Amazon EKS cluster usage in /.test(d.description)), `the EKS per-cluster fee in ${region}`).pricePerUnit.USD);

  const ebs = await awsFlat("AmazonEC2", { productFamily: "Storage", volumeApiName: "gp3", regionCode: region }, `EBS gp3 storage in ${region}`);
  const rdsStorage = await awsFlat(
    "AmazonRDS",
    { productFamily: "Database Storage", regionCode: region, deploymentOption: "Single-AZ", databaseEngine: "PostgreSQL", volumeType: "General Purpose-GP3" },
    `RDS gp3 storage (PostgreSQL/Single-AZ) in ${region}`,
  );

  // S3 Standard is volume-tiered; the card carries the first tier only.
  const s3Dims = awsDimensions(await awsProducts("AmazonS3", { productFamily: "Storage", volumeType: "Standard", regionCode: region }));
  const s3 = Number(only(s3Dims.filter((d) => d.beginRange === "0"), `the first S3 Standard storage tier in ${region}`).pricePerUnit.USD);

  return [
    `# fetched ${TODAY} from the AWS Price List Query API`,
    `#   (POST https://api.pricing.us-east-1.amazonaws.com/ AWSPriceListService.GetProducts,`,
    `#    SigV4-signed; needs AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY).`,
    `as_of_aws = "${TODAY}"`,
    ``,
    `aws = {`,
    `    # EC2 Compute Instance, Linux, Shared tenancy, no pre-installed software,`,
    `    # capacitystatus=Used, "No License required".`,
    `    # https://aws.amazon.com/ec2/pricing/on-demand/`,
    `    compute_hour = {`,
    `        "${region}" = {`,
    ...compute.map(([k, v]) => `            "${k}" = ${usd(v)}`),
    `        }`,
    `    }`,
    ``,
    `    # EKS cluster hour, usagetype USE1-AmazonEKS-Hours:perCluster. Charged per`,
    `    # cluster whatever its size. https://aws.amazon.com/eks/pricing/`,
    `    control_plane = {`,
    `        "${region}" = {sku = "EKS cluster", usd_hour = ${usd(eks)}}`,
    `    }`,
    ``,
    `    # EBS gp3 provisioned storage. The vm/aws backend sets only`,
    `    # rootBlockDevice.volumeSize, so the provider default volume type (gp3)`,
    `    # applies. The 3000 baseline IOPS and 125 MB/s are free; provisioned`,
    `    # extras are not priced here. https://aws.amazon.com/ebs/pricing/`,
    `    root_disk = {`,
    `        "${region}" = {sku = "EBS gp3", gb_month = ${usd(ebs)}}`,
    `    }`,
    ``,
    `    # RDS Database Instance, PostgreSQL, Single-AZ, "No license required".`,
    `    # https://aws.amazon.com/rds/postgresql/pricing/`,
    `    db_instance_hour = {`,
    `        "${region}" = {`,
    ...db.map(([k, v]) => `            "${k}" = ${usd(v)}`),
    `        }`,
    `    }`,
    ``,
    `    # RDS General Purpose-GP3 storage, PostgreSQL, Single-AZ.`,
    `    db_storage = {`,
    `        "${region}" = {sku = "RDS gp3 storage", gb_month = ${usd(rdsStorage)}}`,
    `    }`,
    ``,
    `    # S3 Standard, TimedStorage-ByteHrs, the first 50 TB tier (beginRange 0).`,
    `    # Volume tiers above 50 TB are cheaper and are NOT modelled: an estate big`,
    `    # enough to reach them is negotiating a private rate anyway.`,
    `    # https://aws.amazon.com/s3/pricing/`,
    `    object = {`,
    `        "${region}" = {sku = "S3 Standard", gb_month = ${usd(s3)}}`,
    `    }`,
    `}`,
  ].join("\n");
}

// ── Azure: Retail Prices API (anonymous) ─────────────────────────────────────

type AzureItem = {
  armSkuName: string;
  skuName: string;
  meterName: string;
  productName: string;
  retailPrice: number;
  unitOfMeasure: string;
  tierMinimumUnits: number;
  type: string;
};

async function azureItems(filter: string): Promise<AzureItem[]> {
  const out: AzureItem[] = [];
  let url: string | null = `https://prices.azure.com/api/retail/prices?currencyCode='USD'&$filter=${encodeURIComponent(filter)}`;
  while (url) {
    const res: Response = await fetch(url);
    if (!res.ok) fail(`Azure Retail Prices API ${res.status} for ${filter}: ${await res.text()}`);
    const json = (await res.json()) as { Items: AzureItem[]; NextPageLink: string | null };
    out.push(...json.Items);
    url = json.NextPageLink;
  }
  return out;
}

/**
 * Azure managed disks are sold by tier, and the tier's SIZE is documentation
 * rather than a field on the meter. This is that table.
 * https://learn.microsoft.com/azure/virtual-machines/disks-types#standard-hdds
 */
const AZURE_HDD_TIERS: [tier: string, gb: number][] = [
  ["S4", 32],
  ["S6", 64],
  ["S10", 128],
  ["S15", 256],
  ["S20", 512],
  ["S30", 1024],
  ["S40", 2048],
  ["S50", 4096],
  ["S60", 8192],
  ["S70", 16384],
  ["S80", 32767],
];

/**
 * Flexible Server compute comes in two billing shapes and the SKU name says
 * which: `B_Standard_B1ms` is metered per instance under its own uppercased
 * name, `GP_Standard_D2s_v3` is metered per vCore under a series product. An
 * SKU matching neither is a ladder change this generator has not been taught,
 * and must stop the run rather than be approximated.
 */
function azureDbMeter(sku: string): { kind: "flat"; skuName: string } | { kind: "vcore"; product: string; vcores: number } {
  const burstable = /^B_Standard_(B\d+m?s)$/.exec(sku);
  if (burstable) return { kind: "flat", skuName: burstable[1]!.toUpperCase() };
  const gp = /^GP_Standard_D(\d+)s_v(\d)$/.exec(sku);
  if (gp) return { kind: "vcore", product: `Azure Database for PostgreSQL Flexible Server General Purpose Dsv${gp[2]} Series Compute`, vcores: Number(gp[1]) };
  fail(
    `Flexible Server SKU '${sku}' is neither a Burstable (B_Standard_*) nor a General Purpose Dsv* shape, so this generator does not know which Azure meter prices it. Teach azureDbMeter() the new family in tools/pricing/src/refresh-rates.ts.`,
  );
}

async function buildAzure(inv: Inventory): Promise<string> {
  const region = inv.region;
  const consumption = `armRegionName eq '${region}' and priceType eq 'Consumption'`;

  const compute: [string, number][] = [];
  for (const machine of inv.compute) {
    const items = await azureItems(`serviceName eq 'Virtual Machines' and armSkuName eq '${machine}' and ${consumption}`);
    // Windows meters carry the OS licence; Spot and Low Priority are not
    // on-demand. What is left must be the single Linux pay-as-you-go meter.
    const linux = items.filter((i) => !/Windows/.test(i.productName) && !/Spot|Low Priority/.test(i.meterName));
    compute.push([machine, only(linux, `the Linux on-demand meter for ${machine} in ${region}`).retailPrice]);
  }

  // AKS: the cluster/azure backend never sets skuTier, so the control plane
  // is the Free tier and genuinely costs nothing. The Standard tier is
  // fetched anyway so the comment can name the real alternative.
  const aksItems = await azureItems(`serviceName eq 'Azure Kubernetes Service' and ${consumption}`);
  const aksStandard = only(aksItems.filter((i) => i.meterName === "Standard Uptime SLA"), `the AKS Standard tier meter in ${region}`).retailPrice;

  const diskItems = await azureItems(`serviceName eq 'Storage' and ${consumption} and contains(productName, 'Standard HDD Managed Disks')`);
  const tiers: [string, number, number][] = AZURE_HDD_TIERS.map(([tier, gb]) => [
    tier,
    gb,
    only(diskItems.filter((i) => i.meterName === `${tier} LRS Disk`), `the ${tier} LRS managed-disk meter in ${region}`).retailPrice,
  ]);

  const pgItems = await azureItems(`serviceName eq 'Azure Database for PostgreSQL' and ${consumption}`);
  const db: [string, number, string][] = inv.db.map((sku) => {
    const meter = azureDbMeter(sku);
    if (meter.kind === "flat") {
      const hit = only(
        pgItems.filter((i) => i.productName === "Azure Database for PostgreSQL Flexible Server Burstable BS Series Compute" && i.skuName === meter.skuName),
        `the Burstable ${meter.skuName} meter in ${region}`,
      );
      return [sku, hit.retailPrice, `meter "${meter.skuName}", per instance`];
    }
    const perVcore = only(
      pgItems.filter((i) => i.productName === meter.product && i.meterName === "vCore" && i.skuName === "1 vCore"),
      `the per-vCore meter of ${meter.product} in ${region}`,
    ).retailPrice;
    return [sku, Number((perVcore * meter.vcores).toFixed(8)), `${meter.vcores} * ${perVcore}`];
  });

  const pgStorage = only(
    pgItems.filter((i) => i.productName === "Azure Database for PostgreSQL Flex Server Storage" && i.skuName === "Storage"),
    `the Flexible Server storage meter in ${region}`,
  ).retailPrice;

  const blobItems = await azureItems(`serviceName eq 'Storage' and ${consumption} and contains(meterName, 'Hot LRS Data Stored')`);
  const blob = only(
    blobItems.filter((i) => i.productName === "General Block Blob v2" && i.tierMinimumUnits === 0),
    `the first Hot LRS block-blob storage tier in ${region}`,
  ).retailPrice;

  return [
    `# fetched ${TODAY} from the Azure Retail Prices API`,
    `#   (GET https://prices.azure.com/api/retail/prices?currencyCode='USD'&$filter=...,`,
    `#    anonymous — no credentials of any kind).`,
    `as_of_azure = "${TODAY}"`,
    ``,
    `azure = {`,
    `    # Virtual Machines, Consumption, ${region}, Linux (the Windows meters carry`,
    `    # the licence and are excluded by productName, Spot and Low Priority by`,
    `    # meterName).`,
    `    # https://azure.microsoft.com/pricing/details/virtual-machines/linux/`,
    `    compute_hour = {`,
    `        "${region}" = {`,
    ...compute.map(([k, v]) => `            "${k}" = ${usd(v)}`),
    `        }`,
    `    }`,
    ``,
    `    # AKS: the cluster/azure backend leaves skuTier unset, so the cluster runs`,
    `    # on the FREE tier — a real $0 control plane with no uptime SLA, not a`,
    `    # missing rate. The Standard tier (meter "Standard Uptime SLA") is`,
    `    # $${usd(aksStandard)}/hour in ${region}; switch this cell to it the day the backend`,
    `    # starts setting skuTier: Standard. \`lib.k\` attaches a note to every Azure`,
    `    # cluster estimate so the zero never reads as a bug.`,
    `    # https://azure.microsoft.com/pricing/details/kubernetes-service/`,
    `    control_plane = {`,
    `        "${region}" = {sku = "AKS Free tier", usd_hour = 0.0}`,
    `    }`,
    ``,
    `    # Standard HDD managed disks (Standard_LRS), ${region} — what the vm/azure`,
    `    # backend asks for in osDisk.storageAccountType. Azure bills a managed`,
    `    # disk by PROVISIONED TIER, not by the gigabyte, so this is the S-tier`,
    `    # ladder and the price of a 40 GiB disk is the price of an S6 (64 GiB).`,
    `    # Tier -> size comes from the Azure managed-disk docs; the price of each`,
    `    # is the "<tier> LRS Disk" meter at 1/Month.`,
    `    # https://azure.microsoft.com/pricing/details/managed-disks/`,
    `    root_disk = {`,
    `        "${region}" = {`,
    `            sku = "Managed Disk Standard_LRS"`,
    `            tiers = [`,
    ...tiers.map(([tier, gb, price]) => `                {gb = ${gb}, usd_month = ${usd(price)}} # ${tier}`),
    `            ]`,
    `        }`,
    `    }`,
    ``,
    `    # Azure Database for PostgreSQL Flexible Server compute, ${region}. Two`,
    `    # billing shapes, both real: Burstable is metered per INSTANCE, General`,
    `    # Purpose Dsv3 per vCORE, so the GP cells are vCores times that meter.`,
    `    # https://azure.microsoft.com/pricing/details/postgresql/flexible-server/`,
    `    db_instance_hour = {`,
    `        "${region}" = {`,
    ...db.map(([k, v, note]) => `            "${k}" = ${usd(v)} # ${note}`),
    `        }`,
    `    }`,
    ``,
    `    # Flexible Server storage ("Storage Data Stored"). Azure rounds a request`,
    `    # up to a fixed step (postgres/azure storage_mb_for), so the billed size`,
    `    # is usually larger than the one asked for; lib.k prices the rounded size.`,
    `    db_storage = {`,
    `        "${region}" = {sku = "Flexible Server storage", gb_month = ${usd(pgStorage)}}`,
    `    }`,
    ``,
    `    # Blob Storage, General Block Blob v2, Hot LRS Data Stored, first tier`,
    `    # (tierMinimumUnits 0). https://azure.microsoft.com/pricing/details/storage/blobs/`,
    `    object = {`,
    `        "${region}" = {sku = "Blob Hot LRS", gb_month = ${usd(blob)}}`,
    `    }`,
    `}`,
  ].join("\n");
}

// ── GCP: Cloud Billing Catalog API (needs an API key) ────────────────────────

type GcpSku = {
  skuId: string;
  description: string;
  category: { resourceFamily: string; resourceGroup: string; usageType: string };
  serviceRegions: string[];
  pricingInfo: { pricingExpression: { usageUnit: string; tieredRates: { startUsageAmount: number; unitPrice: { units: string; nanos: number } }[] } }[];
};

function gcpKey(): string {
  const key = process.env.GOOGLE_API_KEY;
  if (!key) {
    fail(
      "the GCP Cloud Billing Catalog API rejects unauthenticated callers and no GOOGLE_API_KEY is set. " +
        "This repo holds no Google credentials on purpose (`just secrets-check`), so the gcp block cannot be machine-refreshed here. " +
        "Create an unrestricted-read API key at https://console.cloud.google.com/apis/credentials with the Cloud Billing API enabled, " +
        "export GOOGLE_API_KEY=..., and re-run. The aws and azure blocks refresh without it: `just price-refresh aws azure`.",
    );
  }
  return key;
}

async function gcpJson<T>(url: string): Promise<T> {
  const res = await fetch(url);
  if (!res.ok) fail(`GCP Cloud Billing API ${res.status} for ${url.replace(/key=[^&]+/, "key=***")}: ${await res.text()}`);
  return (await res.json()) as T;
}

async function gcpServiceId(key: string, displayName: string): Promise<string> {
  const services: { displayName: string; name: string }[] = [];
  let token = "";
  do {
    const page = await gcpJson<{ services: { displayName: string; name: string }[]; nextPageToken?: string }>(
      `https://cloudbilling.googleapis.com/v1/services?pageSize=500&key=${key}${token ? `&pageToken=${token}` : ""}`,
    );
    services.push(...page.services);
    token = page.nextPageToken ?? "";
  } while (token);
  return only(services.filter((s) => s.displayName === displayName), `the Cloud Billing service named '${displayName}'`).name;
}

async function gcpSkus(key: string, service: string, region: string): Promise<GcpSku[]> {
  const out: GcpSku[] = [];
  let token = "";
  do {
    const page = await gcpJson<{ skus: GcpSku[]; nextPageToken?: string }>(
      `https://cloudbilling.googleapis.com/v1/${service}/skus?currencyCode=USD&pageSize=5000&key=${key}${token ? `&pageToken=${token}` : ""}`,
    );
    out.push(...page.skus);
    token = page.nextPageToken ?? "";
  } while (token);
  return out.filter((s) => s.serviceRegions.includes(region) && s.category.usageType === "OnDemand");
}

/**
 * The exact base-tier unit price, in USD, of the one SKU matching `match`.
 * The Cloud Billing catalog is keyed by human-readable description, so a
 * renamed or split SKU must stop the run naming the cell rather than let a
 * neighbouring SKU be selected by position.
 */
function gcpRate(skus: GcpSku[], match: (s: GcpSku) => boolean, what: string): number {
  const sku = only(skus.filter(match), what);
  const tiers = only(sku.pricingInfo, `exactly one pricing expression for ${what}`).pricingExpression.tieredRates;
  const base = only(tiers.filter((t) => t.startUsageAmount === 0), `a zero-start tier for ${what}`);
  return Number(base.unitPrice.units) + base.unitPrice.nanos / 1e9;
}

async function buildGcp(inv: Inventory): Promise<string> {
  const key = gcpKey();
  const region = inv.region;

  const [computeSvc, sqlSvc, gkeSvc, gcsSvc] = await Promise.all([
    gcpServiceId(key, "Compute Engine"),
    gcpServiceId(key, "Cloud SQL"),
    gcpServiceId(key, "Kubernetes Engine"),
    gcpServiceId(key, "Cloud Storage"),
  ]);

  const computeSkus = await gcpSkus(key, computeSvc, region);
  // E2 predefined machines have no per-type SKU: Compute Engine bills a core
  // rate and a RAM rate, and the published per-machine-type price is their
  // sum. e2-medium is the shared-core rung and bills 1 vCPU + 4 GiB.
  const coreRate = gcpRate(computeSkus, (s) => s.category.resourceGroup === "CPU" && /^E2 Instance Core running in /.test(s.description), `the E2 vCPU SKU in ${region}`);
  const ramRate = gcpRate(computeSkus, (s) => s.category.resourceGroup === "RAM" && /^E2 Instance Ram running in /.test(s.description), `the E2 RAM SKU in ${region}`);

  const E2_SHAPES: Record<string, { vcpu: number; gb: number }> = {
    "e2-medium": { vcpu: 1, gb: 4 }, // shared-core: 2 vCPUs exposed, 1 billed
  };
  const compute: [string, number, string][] = inv.compute.map((machine) => {
    const std = /^e2-standard-(\d+)$/.exec(machine);
    const shape = std ? { vcpu: Number(std[1]), gb: Number(std[1]) * 4 } : E2_SHAPES[machine];
    if (!shape) {
      fail(
        `machine type '${machine}' is not an E2 shape this generator knows how to decompose into vCPU + RAM SKUs. Compute Engine publishes no per-machine-type SKU, so add the shape to E2_SHAPES in tools/pricing/src/refresh-rates.ts (or teach it the new family) rather than letting it be mispriced.`,
      );
    }
    return [machine, Number((shape.vcpu * coreRate + shape.gb * ramRate).toFixed(8)), `${shape.vcpu} vCPU + ${shape.gb} GiB`];
  });

  const pdStandard = gbMonthFromHour(
    gcpRate(computeSkus, (s) => s.category.resourceGroup === "PDStandard" && /^Storage PD Capacity/.test(s.description), `the pd-standard capacity SKU in ${region}`),
  );

  const gkeSkus = await gcpSkus(key, gkeSvc, region);
  const gkeFee = gcpRate(gkeSkus, (s) => /Cluster Management Fee/i.test(s.description) && /Zonal/i.test(s.description), `the GKE zonal cluster management fee SKU in ${region}`);

  const sqlSkus = await gcpSkus(key, sqlSvc, region);
  const sqlVcpu = gcpRate(sqlSkus, (s) => /^Cloud SQL for PostgreSQL: Zonal - vCPU/.test(s.description), `the Cloud SQL PostgreSQL zonal vCPU SKU in ${region}`);
  const sqlRam = gcpRate(sqlSkus, (s) => /^Cloud SQL for PostgreSQL: Zonal - RAM/.test(s.description), `the Cloud SQL PostgreSQL zonal RAM SKU in ${region}`);
  const sqlStorage = gbMonthFromHour(
    gcpRate(sqlSkus, (s) => /^Cloud SQL for PostgreSQL: Zonal - Standard storage/.test(s.description), `the Cloud SQL PostgreSQL zonal SSD storage SKU in ${region}`),
  );

  // db-custom-<vCPU>-<memoryMiB> is billed as those two components.
  const db: [string, number, string][] = inv.db.map((tier) => {
    const m = /^db-custom-(\d+)-(\d+)$/.exec(tier);
    if (!m) {
      fail(
        `Cloud SQL tier '${tier}' is not a db-custom-<vCPU>-<memoryMiB> shape, so its vCPU and memory cannot be read off the name. Teach the generator the new family in tools/pricing/src/refresh-rates.ts.`,
      );
    }
    const vcpu = Number(m[1]);
    const gib = Number(m[2]) / 1024;
    return [tier, Number((vcpu * sqlVcpu + gib * sqlRam).toFixed(8)), `${vcpu} * ${sqlVcpu} + ${gib} * ${sqlRam}`];
  });

  const gcsSkus = await gcpSkus(key, gcsSvc, region);
  const gcs = gbMonthFromHour(
    gcpRate(gcsSkus, (s) => /^Standard Storage/.test(s.description) && s.category.resourceGroup === "RegionalStorage", `the regional Standard Storage SKU in ${region}`),
  );

  return [
    `# fetched ${TODAY} from the GCP Cloud Billing Catalog API`,
    `#   (GET https://cloudbilling.googleapis.com/v1/services/<id>/skus, needs`,
    `#    GOOGLE_API_KEY — the API rejects unauthenticated callers outright).`,
    `as_of_gcp = "${TODAY}"`,
    ``,
    `gcp = {`,
    `    # Compute Engine bills E2 machines as a vCPU SKU ($${usd(coreRate)}/vCPU-hour) plus a`,
    `    # RAM SKU ($${usd(ramRate)}/GiB-hour); there is no per-machine-type SKU, and the`,
    `    # published per-type price is exactly that sum. e2-medium is shared-core:`,
    `    # two vCPUs are exposed and one is billed.`,
    `    # https://cloud.google.com/products/compute/pricing/general-purpose#e2-machine-types`,
    `    compute_hour = {`,
    `        "${region}" = {`,
    ...compute.map(([k, v, note]) => `            "${k}" = ${usd(v)} # ${note}`),
    `        }`,
    `    }`,
    ``,
    `    # Flat GKE cluster management fee, identical in every region and for every`,
    `    # topology (zonal, regional, Autopilot). The one-free-zonal-cluster credit`,
    `    # is an account-level free tier and is deliberately not modelled.`,
    `    # https://cloud.google.com/kubernetes-engine/pricing#cluster_management_fee`,
    `    control_plane = {`,
    `        "${region}" = {sku = "GKE cluster management fee", usd_hour = ${usd(gkeFee)}}`,
    `    }`,
    ``,
    `    # Persistent Disk "Standard provisioned space" (per GiB-hour x 730).`,
    `    # pd-standard because the vm/gcp backend sets bootDisk.initializeParams`,
    `    # without a \`type\`, and the Terraform-derived provider defaults that to`,
    `    # pd-standard. The first 30 GiB/month per account is free and is not`,
    `    # modelled. https://cloud.google.com/compute/disks-image-pricing#persistentdisk`,
    `    root_disk = {`,
    `        "${region}" = {sku = "PD Standard (pd-standard)", gb_month = ${usd(pdStandard)}}`,
    `    }`,
    ``,
    `    # Cloud SQL Enterprise edition, General Purpose machine series: vCPU`,
    `    # $${usd(sqlVcpu)}/hour and memory $${usd(sqlRam)}/GiB-hour. A db-custom-<vCPU>-<MiB>`,
    `    # tier is billed as those two components, so each cell below is the sum`,
    `    # and the arithmetic is in the comment.`,
    `    # https://cloud.google.com/sql/pricing#pg-instance-pricing`,
    `    db_instance_hour = {`,
    `        "${region}" = {`,
    ...db.map(([k, v, note]) => `            "${k}" = ${usd(v)} # ${note}`),
    `        }`,
    `    }`,
    ``,
    `    # Cloud SQL SSD storage capacity, non-HA (per GiB-hour x 730).`,
    `    db_storage = {`,
    `        "${region}" = {sku = "Cloud SQL SSD storage", gb_month = ${usd(sqlStorage)}}`,
    `    }`,
    ``,
    `    # Cloud Storage Standard, regional (per GiB-hour x 730). Dual-region and`,
    `    # multi-region buckets cost more and are a different \`location\`, so they`,
    `    # are a different rate.`,
    `    # https://cloud.google.com/storage/pricing#storage-pricing`,
    `    object = {`,
    `        "${region}" = {sku = "Cloud Storage Standard (regional)", gb_month = ${usd(gcs)}}`,
    `    }`,
    `}`,
  ].join("\n");
}

// ── splicing ─────────────────────────────────────────────────────────────────

const BUILDERS: Record<Cloud, (inv: Inventory) => Promise<string>> = { aws: buildAws, gcp: buildGcp, azure: buildAzure };

function blockBounds(source: string, cloud: Cloud): { start: number; end: number; lines: string[] } {
  const lines = source.split("\n");
  const start = lines.findIndex((l) => l.startsWith(`# >>> GENERATED ${cloud}`));
  const end = lines.findIndex((l) => l.startsWith(`# <<< END ${cloud}`));
  if (start < 0 || end < 0 || end < start) {
    fail(`${relative(root, ratesPath)} has no '# >>> GENERATED ${cloud}' ... '# <<< END ${cloud}' block to rewrite.`);
  }
  return { start, end, lines };
}

function asOfOf(block: string, cloud: Cloud): string {
  const m = new RegExp(`as_of_${cloud} = "(\\d{4}-\\d{2}-\\d{2})"`).exec(block);
  if (!m) fail(`the ${cloud} block carries no as_of_${cloud} date, so its staleness cannot be judged.`);
  return m[1]!;
}

/**
 * The provenance comment and the as_of line differ on every re-fetch by
 * construction, so `--check` compares the DATA and reports the date
 * separately — otherwise every check would read as drift.
 */
const strip = (block: string): string =>
  block.replace(/^# fetched .*$|^# hand-entered .*$|^as_of_\w+ = ".*"$/gm, "").replace(/\n{2,}/g, "\n").trim();

async function main(): Promise<void> {
  const argv = process.argv.slice(2);
  const check = argv.includes("--check");
  const named = argv.filter((a) => !a.startsWith("--"));
  const unknown = named.filter((a) => a !== "all" && !CLOUDS.includes(a as Cloud));
  if (unknown.length) fail(`unknown cloud(s) ${unknown.join(", ")} — expected any of ${CLOUDS.join(", ")} (or nothing, which means all).`);
  const wanted: Cloud[] = named.length && !named.includes("all") ? (named as Cloud[]) : [...CLOUDS];

  const inv = inventory();
  let source = readFileSync(ratesPath, "utf8");
  let drift = 0;

  for (const cloud of wanted) {
    const built = await BUILDERS[cloud](inv[cloud]);
    const { start, end, lines } = blockBounds(source, cloud);
    const current = lines.slice(start + 1, end).join("\n").replace(/\s+$/, "");

    if (check) {
      if (strip(current) !== strip(built)) {
        drift = 1;
        console.error(`✗ ${cloud}: the committed rates no longer match ${cloud}'s pricing API.`);
        for (const line of diffLines(strip(current), strip(built))) console.error(`    ${line}`);
      } else {
        console.log(`✓ ${cloud}: committed rates match the pricing API`);
      }
      const age = Math.floor((Date.now() - Date.parse(`${asOfOf(current, cloud)}T00:00:00Z`)) / 86_400_000);
      if (age > STALENESS_DAYS) {
        drift = 1;
        console.error(`✗ ${cloud}: as_of_${cloud} is ${age} days old (contract: ${STALENESS_DAYS}). Run \`just price-refresh ${cloud}\`.`);
      }
      continue;
    }

    source = [...lines.slice(0, start + 1), built, ...lines.slice(end)].join("\n");
    console.log(`refreshed ${cloud} in ${relative(root, ratesPath)}`);
  }

  if (check) process.exit(drift);
  writeFileSync(ratesPath, source);
}

/** Minimal line diff, enough to point at the cell that moved. */
function diffLines(a: string, b: string): string[] {
  const left = a.split("\n");
  const right = b.split("\n");
  const out: string[] = [];
  for (let i = 0; i < Math.max(left.length, right.length); i++) {
    if (left[i] !== right[i]) {
      if (left[i] !== undefined) out.push(`- ${left[i]}`);
      if (right[i] !== undefined) out.push(`+ ${right[i]}`);
    }
  }
  return out.slice(0, 40);
}

await main();
