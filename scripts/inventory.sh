#!/usr/bin/env bash
# Inventory of the roots of the SAP labs: what each root creates on an empty account, counted from a plan of terraform
# test against mock providers. write regenerates <lab>/docs/inventory.md of each lab and docs/diagrams/inventory/;
# check generates into a temporary directory and fails, naming the file, on any difference.

# Copied from ci/inventory.sh of svp-infra, the same way of counting, changed for this repository's roots and pages.
# The plans run on a copy of the files git tracks below the labs, minus every file that may hold personal values (denied
# below), in a container without network or credential; only init reaches the registries.
# scripts/inventory/<slug>.tftest.hcl holds the mocks of a root, notes() below what they assume.

# Usage: scripts/inventory.sh write|check
#
# The jq programs and the page's text hold literal $ signs and backticks.
# shellcheck disable=SC2016
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
: "${TERRAFORM_IMAGE:?set by make inventory}" "${D2_IMAGE:?set by make inventory}" "${JQ_IMAGE:?set by make inventory}"
diagrams=docs/diagrams/inventory
cache=$repo/.plugin-cache

# No credential reaches a container: no AWS_* variable lives on in this shell, and docker gets no -e of one.
while IFS= read -r v; do unset "$v"; done < <(compgen -e | grep '^AWS_' || true)
unset DOCKER_DEFAULT_PLATFORM

# jq from JQ_IMAGE, the same version on every machine; it reads only below $work, mounted read-only.
jq() {
  docker run --rm -i --network none --user "$(id -u):$(id -g)" -v "$work:$work:ro" "$JQ_IMAGE" "$@"
}

LABS=(multi-account-networking serverless-variant multi-region-dr dms-migration data-scaling)
ROOTS=("multi-account-networking/account" "multi-account-networking/core" "multi-account-networking/hybrid"
  "serverless-variant/terraform" "multi-region-dr/terraform" "dms-migration/terraform" "data-scaling/postgres"
  "data-scaling/valkey")

fail() {
  echo "FAIL: inventory: $*" >&2
  exit 1
}

# denied PATH: whether the copy leaves PATH out. git already leaves out what .gitignore lists; this list holds even for
# a file someone added with git add -f. Test files of the repository are left out too: only the inventory's run.
denied() {
  case /$1 in
    *.example) return 1 ;;
    */.terraform/* | */.session/* | */.envrc | *.tfstate | *.tfstate.* | *.tfplan | */tfplan) return 0 ;;
    *.auto.tfvars | *.auto.tfvars.json | */terraform.tfvars | */terraform.tfvars.json) return 0 ;;
    */backend.hcl | */backend-*.hcl | */override.tf | */override.tf.json | *_override.tf | *_override.tf.json) return 0 ;;
    *.tftest.hcl | *.tftest.json) return 0 ;;
    *) return 1 ;;
  esac
}

# copy_tree DIR: the files git tracks (and new ones it does not ignore) below the labs of LABS into DIR, regular files
# only: a symbolic link could point outside the repository.
copy_tree() {
  local dir=$1 f
  while IFS= read -r -d '' f; do
    [ -f "$repo/$f" ] && [ ! -L "$repo/$f" ] || continue
    denied "$f" && continue
    if ! mkdir -p "$dir/$(dirname "$f")" || ! cp "$repo/$f" "$dir/$f"; then fail "copy $f"; fi
  done < <(git -C "$repo" ls-files -z --cached --others --exclude-standard -- "${LABS[@]/%//}")
  while IFS= read -r f; do
    if denied "${f#"$dir"/}"; then fail "the copy holds $f, which the inventory never reads"; fi
  done < <(find "$dir" -type f)
}

# check_roots: a directory of the copy with a *.tf file outside modules/ is a root, as LIST_DIRS of the Makefile finds
# them; one missing from ROOTS would never be counted.
check_roots() {
  local d r found rc=0
  while IFS= read -r d; do
    found=
    for r in "${ROOTS[@]}"; do [ "$r" != "$d" ] || found=1; done
    [ -n "$found" ] || { echo "FAIL: inventory: $d is a Terraform root missing from ROOTS of scripts/inventory.sh" >&2 && rc=1; }
  done < <(cd "$copy" && find . -name '*.tf' | sed 's|/[^/]*$||; s|^\./||' | grep -v -E '(^|/)modules(/|$)' | sort -u)
  [ "$rc" = 0 ] || exit 1
}

# slug ROOT: the name of ROOT's mocks and diagram: the lab when the root is <lab>/terraform, else <lab>-<directory>.
slug() {
  case $1 in */terraform) echo "${1%/terraform}" ;; *) echo "${1//\//-}" ;; esac
}

# var_files ROOT: the -var-file arguments of ROOT, relative to it: every committed *.auto.tfvars.example, whose
# values stand in for the personal ones that no committed file holds.
var_files() {
  local root=$1 f
  for f in "$copy/$root"/*.auto.tfvars.example; do [ ! -f "$f" ] || echo "-var-file=$(basename "$f")"; done
}

# The name of the override in the copy: denied() keeps every override file of the repository out of the copy, so this
# one is always the generator's own.
OVERRIDE=zz_inventory_ephemeral_override.tf

# assigned root|override FILE...: "module.<name>.<argument>" or "locals.<name>", sorted, for each value that a module
# call or a locals block of FILE... sets. root: the arguments of a formatted root whose value reads an ephemeral block.
# override: every assignment at any depth, so a nested or odd line of an override fails the comparison, never hides.
assigned() {
  local mode=$1
  shift
  awk -v mode="$mode" '
    /^[a-z]/ { b = ""; if ($1 == "locals") b = "locals"; if ($1 == "module") { b = $2; gsub(/"/, "", b); b = "module." b } next }
    /^}/ { b = ""; next }
    b == "" { next }
    mode == "root" && /^  [A-Za-z_][A-Za-z0-9_-]*[[:space:]]*=/ && /ephemeral\./ ||
    mode == "override" && /^[[:space:]]+[A-Za-z_][A-Za-z0-9_-]*[[:space:]]*=/ {
      a = $0; sub(/^[[:space:]]+/, "", a); sub(/[[:space:]]*=.*/, "", a); print b "." a }' "$@" | sort -u
}

# override ROOT: mock providers cannot answer an ephemeral resource, even one turned off with count = 0. So the copy of
# a root that declares one loses its ephemeral blocks, and scripts/inventory/<slug>.override.hcl, copied in as
# $OVERRIDE, passes fake values to the module arguments and locals that read them. It may hold nothing else: no
# managed resource is added, removed or changed, and an ephemeral value is never one, so the counts stay the root's.
override() {
  local root=$1 f tf extra missing
  f=$repo/scripts/inventory/$(slug "$root").override.hcl
  if ! grep -q "^ephemeral " "$copy/$root"/*.tf; then
    [ ! -f "$f" ] || fail "$(basename "$f"): $root declares no ephemeral block"
    return 0
  fi
  [ -f "$f" ] || fail "$root declares an ephemeral block, which mock providers cannot answer: add $(basename "$f")"
  awk '
    /^[a-z]/ { kind = $1; if (kind != "module" && kind != "locals") bad("a " kind " block"); next }
    kind == "module" && /^[[:space:]]*(source|version|providers|count|for_each|depends_on)[[:space:]]*=/ { bad($0) }
    function bad(what) { print "line " NR ": " what; exit 1 }' "$f" >"$work/override.log" ||
    fail "$(basename "$f") may only set module arguments and locals: $(cat "$work/override.log")"
  assigned root "$copy/$root"/*.tf >"$work/ephemeral.args"
  assigned override "$f" >"$work/override.args"
  extra=$(comm -13 "$work/ephemeral.args" "$work/override.args" | paste -s -d ' ' -)
  missing=$(comm -23 "$work/ephemeral.args" "$work/override.args" | paste -s -d ' ' -)
  [ -z "$extra$missing" ] || fail "$(basename "$f") must set exactly the values of $root that read an ephemeral block:" \
    "extra ${extra:-none}, missing ${missing:-none}"
  for tf in "$copy/$root"/*.tf; do
    if ! awk '/^ephemeral / { skip = !/}[[:space:]]*$/; next } !skip { print } skip && /^}/ { skip = 0 }' "$tf" >"$tf.new" ||
      ! mv "$tf.new" "$tf"; then
      fail "strip the ephemeral blocks of $tf"
    fi
  done
  cp "$f" "$copy/$root/$OVERRIDE"
}

# The plugin cache has one writer at a time, as with make test (CACHE_LOCK of the Makefile).
lock() {
  local n=0
  mkdir -p "$cache/terraform" "$cache/tflint" || fail "mkdir $cache"
  until mkdir "$cache/lock" 2>/dev/null; do
    n=$((n + 1))
    [ $n -lt 600 ] || fail "$cache/lock held for 10 minutes; remove it if no make runs"
    sleep 1
  done
  locked=1
}
unlock() {
  [ -z "$locked" ] || rmdir "$cache/lock"
  locked=
}

TF_RUN=(docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -e CHECKPOINT_DISABLE=1 -e TF_IN_AUTOMATION=1
  -e TF_DATA_DIR=/tfdata)

# plan ROOT: the plan JSON of ROOT's run "inventory" into $work/plan.json.
plan() {
  local root=$1 data rc=0 out=$work/test.json
  data=$(mktemp -d "$work/data.XXXXXX")
  [ -f "$repo/scripts/inventory/$(slug "$root").tftest.hcl" ] ||
    fail "no scripts/inventory/$(slug "$root").tftest.hcl for $root"
  mkdir -p "$copy/$root/tests"
  cp "$repo/scripts/inventory/$(slug "$root").tftest.hcl" "$copy/$root/tests/inventory.tftest.hcl"
  override "$root"
  lock
  if ! "${TF_RUN[@]}" -e TF_PLUGIN_CACHE_DIR=/plugin-cache -e TF_PLUGIN_CACHE_MAY_BREAK_DEPENDENCY_LOCK_FILE=1 \
    -v "$data:/tfdata" -v "$cache/terraform:/plugin-cache" -v "$copy:/src:ro" -w "/src/$root" \
    "$TERRAFORM_IMAGE" init -backend=false -input=false -no-color -lockfile=readonly >"$work/init.log" 2>&1; then
    cat "$work/init.log" >&2
    fail "terraform init $root"
  fi
  unlock
  # shellcheck disable=SC2046 # one -var-file argument per line, without blanks
  "${TF_RUN[@]}" --network none -v "$data:/tfdata" -v "$cache/terraform:/plugin-cache:ro" -v "$copy:/src:ro" \
    -w "/src/$root" "$TERRAFORM_IMAGE" test -json -verbose -no-color $(var_files "$root") >"$out" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ] || ! jq -e 'select(.type == "test_summary") | .test_summary.status == "pass"' "$out" >/dev/null; then
    jq -r 'select(.["@level"] == "error") | .["@message"] + "\n" + (.diagnostic.detail // "")
      + (.diagnostic.range | if . then "\n  at \(.filename):\(.start.line)" else "" end)' "$out" >&2 ||
      cat "$out" >&2
    fail "terraform test of $root with scripts/inventory/$(slug "$root").tftest.hcl"
  fi
  jq -c 'select(.type == "test_plan" and .["@testrun"] == "inventory") | .test_plan' "$out" >"$work/plan.json"
  [ -s "$work/plan.json" ] || fail "terraform test of $root printed no plan of run \"inventory\""
}

# records ROOT: $work/plan.json as "root<TAB>part<TAB>type<TAB>action" lines, one per managed resource. The part is the
# root's module call, or the .tf file of the root that declares the resource. An import counts apart from a create.
records() {
  local root=$1 module type name action file
  jq -r '.resource_changes[]? | select(.mode == "managed")
    | [((.module_address // "" | capture("^(?<m>module\\.[A-Za-z0-9_-]+)") | .m)? // "-"), .type, .name,
       (if .change.importing then "import" else .change.actions | if . == ["create"] then "create"
         else join("-") end end)] | @tsv' "$work/plan.json" >"$work/changes.tsv"
  while IFS=$'\t' read -r module type name action; do
    if [ "$module" = - ]; then
      file=$(grep -lE "^resource \"$type\" \"$name\"" "$copy/$root"/*.tf | head -n 1) || true
      [ -n "$file" ] || fail "$root: no .tf file declares resource $type.$name"
      module=$(basename "$file")
    fi
    [ "$action" = create ] || [ "$action" = import ] ||
      fail "$root: $module $type.$name would $action on an empty account; only create and import are expected"
    printf '%s\t%s\t%s\t%s\n' "$root" "$module" "$type" "$action"
  done <"$work/changes.tsv"
}

# The AWS service of a resource type: the label of the diagrams and the pages, and the icon of docs/diagrams/icons/.
# The first match wins, so a narrow prefix comes before a wide one. A new type outside this table fails, so its icon is
# chosen once; a feature of a service takes the service's icon (NAT gateway: VPC, RDS Proxy: RDS, Resolver: Route 53).
SERVICES='def service:
  [["^aws_api_gateway_", "API Gateway", "api-gateway"], ["^aws_cloudwatch_event_", "EventBridge", "eventbridge"],
   ["^aws_cloudwatch_", "CloudWatch", "cloudwatch"],
   ["^aws_(customer_gateway|vpn_)", "Site-to-Site VPN", "site-to-site-vpn"],
   ["^aws_rds_cluster", "Aurora", "aurora"], ["^aws_db_", "RDS", "rds"], ["^aws_dms_", "DMS", "dms"],
   ["^aws_dynamodb_", "DynamoDB", "dynamodb"], ["^aws_ec2_transit_gateway", "Transit Gateway", "transit-gateway"],
   ["^aws_elasticache_", "ElastiCache", "elasticache"], ["^aws_iam_", "IAM", "iam"], ["^aws_kms_", "KMS", "kms"],
   ["^aws_lambda_", "Lambda", "lambda"], ["^aws_lb", "ELB", "elb"],
   ["^aws_organizations_", "Organizations", "organizations"], ["^aws_ram_", "RAM", "ram"],
   ["^aws_route53", "Route 53", "route53"], ["^aws_s3_", "S3", "s3"],
   ["^aws_secretsmanager_", "Secrets Manager", "secrets-manager"], ["^aws_sfn_", "Step Functions", "step-functions"],
   ["^aws_sqs_", "SQS", "sqs"], ["^aws_ssm_", "Systems Manager", "systems-manager"],
   ["^aws_vpc_endpoint", "PrivateLink", "privatelink"],
   ["^aws_(vpc|subnet|route_table|route$|nat_gateway|eip|internet_gateway|security_group|default_security_group)",
    "VPC", "vpc"],
   ["^aws_(instance$|network_interface$|ec2_)", "EC2", "ec2"],
   ["^(random|time|null|tls|archive)_", "Terraform", null]] as $t
  | . as $type | first($t[] | select(. as $r | $type | test($r[0]))) // null
  | if . == null then error("no service for resource type \($type): add it to SERVICES of scripts/inventory.sh")
    else {name: .[1], icon: .[2]} end;'

# The records of one root, from $work/records.tsv, as a JSON array.
root_records() {
  jq -R -s -c --arg root "$1" "$SERVICES"'
    [split("\n")[] | select(length > 0) | split("\t") | select(.[0] == $root)
     | {part: .[1], type: .[2], action: .[3], service: (.[2] | service)}]' "$work/records.tsv"
}

# intro LAB: the opening of LAB's page, in Vietnamese like every page of the labs: what the counts are, how to read
# them, and that each root's section says what the fake values of scripts/inventory/<slug>.tftest.hcl assume.
intro() {
  printf '# Tài nguyên mỗi root của `%s` tạo trên account trống\n' "$1"
  cat <<'EOF'

Trang này đếm, cho mỗi root Terraform của lab, các tài nguyên mà lần `apply` đầu tiên tạo trên account chưa có gì của root đó, chia
theo phần và theo loại, kèm một sơ đồ. Đọc trước khi chạy một root để biết plan đúng ra bao nhiêu `to add` và chúng thuộc dịch vụ
nào; các bước của buổi ở [README của lab](../README.md). Trang và sơ đồ sinh bằng `make inventory` từ plan của `terraform test` trên
provider giả: offline, không credential, không phí. Không sửa tay: `make inventory-check` ở CI đỏ khi trang hay sơ đồ lệch code. Lý
do chọn cách này, và các phương án đã bỏ:
[ADR-0081](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0081-terraform-inventory.md).

## Cách đọc

- Dòng `Plan: …` là dòng tóm tắt `terraform plan` in ra trên account trống; `to import` là tài nguyên root nhận quản qua khối `import`
  thay vì tạo.
- **Phần**: lời gọi module cấp root (`module.<tên>`); tài nguyên khai báo thẳng trong root thì là file `.tf` khai báo nó.
- Bảng theo loại đếm mọi bản của `count`, `for_each`; cột dịch vụ là dịch vụ AWS của icon trên sơ đồ.
- Sơ đồ: mỗi khối một phần, tiêu đề ghi số tài nguyên của phần; mỗi icon một dịch vụ AWS kèm số tài nguyên của dịch vụ đó trong phần.
  Icon lấy từ bộ AWS Architecture Icons ([nguồn và bản](../../docs/diagrams/README.md#icon)).

## Giới hạn

- Số là của **account trống chạy lần đầu**. Chạy root trên account đã có một phần của nó: plan thật chỉ hiện phần còn thiếu cùng các
  thay đổi.
- Giá trị: biến theo mặc định của `variables.tf`, rồi theo `*.auto.tfvars.example` của root nếu có; account id giả dạng
  `000000000000`. Buổi đặt biến khác (file `*.auto.tfvars`) thì số đổi theo.
- Data source trả giá trị giả của `scripts/inventory/<slug>.tftest.hcl` (provider giả, không đọc account). Mỗi root dưới đây nêu giả
  định nào của giá trị giả quyết định số.
EOF
}

# notes SLUG: what the fake values and variables of SLUG's mocks assume, as the list under the root's heading.
notes() {
  case $1 in
    multi-account-networking-account) echo '- Tổ chức đã có, chưa có OU `Infrastructure` hay account `svp-network`. Số không phụ thuộc giá trị
  giả.' ;;
    multi-account-networking-core) echo '- Bốn account (management, `svp-network`, `svp-stg`, `svp-prd`) chưa có gì của lab. Mỗi VPC một zone
  (`availability_zone_id` theo mặc định).' ;;
    multi-account-networking-hybrid) echo '- Root `multi-account-networking/core` đã chạy: data source trả Transit Gateway, hai route table, các
  VPC, subnet, security group, instance probe và Route 53 Profile của nó, với id và CIDR giả có định dạng hợp lệ.' ;;
    serverless-variant) echo '- Account trống. `archive_file` chạy trên provider giả: plan không cần `make lambda-build`, số không
  phụ thuộc binary.' ;;
    multi-region-dr) echo '- Account trống ở cả hai region (`ap-southeast-1` chính, `us-east-1` DR); khoá KMS `aws/rds` của region DR
  là giá trị giả.' ;;
    dms-migration) echo '- Account chưa có `dms-vpc-role`, `dms-cloudwatch-logs-role`, nên lab tạo cả hai: mock đặt
  `create_dms_vpc_role`, `create_dms_logs_role` là `true`, thay giá trị của `dms.auto.tfvars.example` (file cho account đã có role).' ;;
    data-scaling-postgres) echo '- Cả ba phần bật theo `postgres.auto.tfvars.example`: `aurora`, `rds`, `proxy` đều `true`. Tắt một
  phần thì tài nguyên của phần đó (`module.aurora`, `module.rds`, `module.rds_proxy`) rời khỏi plan.' ;;
    data-scaling-valkey) echo '- `shards` theo `valkey.auto.tfvars.example` (2). Số shard không đổi số tài nguyên: một replication
  group giữ mọi shard.' ;;
    *) fail "no notes for $1 in scripts/inventory.sh" ;;
  esac
}

# section ROOT NOTES: the Markdown section of ROOT, from its records on stdin; the page sits at <lab>/docs/.
section() {
  local root=$1 records
  records=$(cat)
  printf '## `%s`\n\n%s\n\n' "$root" "$2"
  jq -r --arg slug "$(slug "$root")" '
    def count($k): group_by(.[$k]) | map({key: .[0][$k], n: length, i: ([.[] | select(.action == "import")] | length),
      service: .[0].service.name});
    def imports: if .i > 0 then " (\(.i) import)" else "" end;
    ([.[] | select(.action == "import")] | length) as $i | ([.[] | select(.action == "create")] | length) as $c
    | "`Plan: \(if $i > 0 then "\($i) to import, " else "" end)\($c) to add, 0 to change, 0 to destroy.`\n",
      "<picture>",
      "  <source media=\"(prefers-color-scheme: dark)\" srcset=\"../../docs/diagrams/inventory/\($slug)-dark.svg\">",
      "  <img src=\"../../docs/diagrams/inventory/\($slug).svg\" alt=\"Tài nguyên của \($slug)\">",
      "</picture>\n",
      "| Phần | Tài nguyên |", "| --- | ---: |",
      (count("part")[] | "| `\(.key)` | \(.n)\(imports) |"),
      "",
      "| Loại | Dịch vụ | Số |", "| --- | --- | ---: |",
      (count("type")[] | "| `\(.key)` | \(.service) | \(.n)\(imports) |")' <<<"$records"
}

# diagram ROOT: the D2 source of ROOT's diagram, from its records on stdin: one block per part, titled with its count,
# holding one icon per AWS service with the service's count; a service of another provider is a line of text.
diagram() {
  jq -r --arg root "$1" '
    def cols($n; $max): [($n | sqrt | ceil), $max, $n] | min;
    # The label sits on the light fill of the block: dark text in both themes, as class sub has.
    "style: {font-color: \"#1A1A1A\"; font-size: 13; bold: false}" as $label |
    (group_by(.part) | map({part: .[0].part, n: length,
      services: (group_by(.service.name) | map({name: .[0].service.name, icon: .[0].service.icon, n: length}))})) as $parts
    | ($parts | length) as $np | cols($np; 4) as $c
    | "# Generated by make inventory from a mock plan of \($root):",
      "# change scripts/inventory.sh or the root, never this file.",
      "vars: {d2-config: {layout-engine: elk; pad: 20}}",
      "...@../tokens",
      "",
      "title: \"\($root): \(length) tài nguyên trên account trống\" {",
      "  shape: text",
      "  near: top-center",
      "  style: {font-size: 18; bold: true}",
      "}",
      "",
      "all: \"\" {",
      "  grid-rows: \(($np + $c - 1) / $c | floor)",
      "  grid-columns: \($c)",
      "  grid-gap: 40",
      "  style: {stroke: transparent; fill: transparent}",
      ($parts | to_entries[] | .key as $k | .value as $p | ($p.services | length) as $ns | ([$ns, 3] | min) as $sc
        | "  p\($k + 1): \"\($p.part) · \($p.n)\" {",
          "    class: workload",
          "    grid-rows: \(($ns + $sc - 1) / $sc | floor)",
          "    grid-columns: \($sc)",
          "    grid-gap: 24",
          ($p.services | to_entries[] | .key as $j | .value
            | if .icon then "    s\($j + 1): \"\(.name) · \(.n)\" {shape: image; icon: ../icons/\(.icon).svg; width: 48; height: 48; \($label)}"
              else "    s\($j + 1): \"\(.name) · \(.n)\" {class: sub}" end),
          "  }"),
      "}"'
}

# render DIR: SVG of every DIR/inventory/*.d2 in the light theme (0) and the dark one (200), as make diagrams renders
# them; DIR is a copy of docs/diagrams/inventory beside tokens.d2 and icons/, the container has no network.
render() {
  local dir=$1 f n theme tail
  for f in "$dir"/inventory/*.d2; do
    n=$(basename "$f" .d2)
    for theme in 0 200; do
      tail=; [ "$theme" = 0 ] || tail=-dark
      if ! docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp --network none --entrypoint d2 -v "$dir:/work" \
        -w /work "$D2_IMAGE" --theme "$theme" --scale 1 "inventory/$n.d2" "inventory/$n$tail.svg" >"$work/d2.log" 2>&1; then
        cat "$work/d2.log" >&2
        fail "d2 $diagrams/$n.d2"
      fi
    done
  done
}

# pages: the page of every lab, relative to the repository, one per line.
pages() {
  local lab
  for lab in "${LABS[@]}"; do echo "$lab/docs/inventory.md"; done
}

# generate OUT: the pages into OUT/<lab>/docs/ and the diagrams into OUT/docs/diagrams/inventory/.
generate() {
  local out=$1 root lab note
  : >"$work/records.tsv"
  for root in "${ROOTS[@]}"; do
    echo "inventory $root" >&2
    plan "$root"
    records "$root" >>"$work/records.tsv"
  done
  mkdir -p "$out/$diagrams"
  for lab in "${LABS[@]}"; do
    mkdir -p "$out/$lab/docs"
    {
      intro "$lab"
      for root in "${ROOTS[@]}"; do
        [ "${root%%/*}" = "$lab" ] || continue
        # Assigned first: a fail inside the substitution of an argument would not stop the script.
        note=$(notes "$(slug "$root")")
        if [ -f "$repo/scripts/inventory/$(slug "$root").override.hcl" ]; then
          note+=$'\n'"- Khi sinh bảng, khối \`ephemeral\` thay bằng giá trị giả của"
          note+=" \`scripts/inventory/$(slug "$root").override.hcl\`"$'\n'"  (provider giả không trả được ephemeral);"
          note+=" ephemeral không phải tài nguyên nên số không đổi."
        fi
        printf '\n'
        root_records "$root" | section "$root" "$note"
      done
    } >"$out/$lab/docs/inventory.md"
  done
  for root in "${ROOTS[@]}"; do
    root_records "$root" | diagram "$root" >"$out/$diagrams/$(slug "$root").d2"
  done
  cp "$repo/docs/diagrams/tokens.d2" "$out/docs/diagrams/"
  cp -R "$repo/docs/diagrams/icons" "$out/docs/diagrams/"
  render "$out/docs/diagrams"
  rm -rf "$out/docs/diagrams/tokens.d2" "$out/docs/diagrams/icons"
}

main() {
  local mode=${1:-} out f page rc=0
  case $mode in write | check) ;; *) echo "usage: scripts/inventory.sh write|check" >&2 && exit 2 ;; esac
  work=$(mktemp -d)
  locked=
  trap 'unlock; rm -rf "$work"' EXIT
  copy=$work/copy
  out=$work/out
  mkdir -p "$copy" "$out"
  copy_tree "$copy"
  check_roots
  generate "$out"
  if [ "$mode" = write ]; then
    mkdir -p "$repo/$diagrams"
    rm -f "$repo/$diagrams"/*.d2 "$repo/$diagrams"/*.svg
    while IFS= read -r page; do
      mkdir -p "$(dirname "$repo/$page")"
      cp "$out/$page" "$repo/$page"
    done < <(pages)
    cp "$out/$diagrams"/* "$repo/$diagrams/"
    echo "inventory: wrote */docs/inventory.md and $diagrams/"
    return
  fi
  for f in $(pages) $(cd "$out" && ls "$diagrams"/*); do
    cmp -s "$out/$f" "$repo/$f" || { echo "FAIL: $f is out of date or missing (run make inventory)" >&2 && rc=1; }
  done
  for f in "$repo/$diagrams"/*; do
    [ -e "$f" ] || continue
    [ -e "$out/$diagrams/$(basename "$f")" ] ||
      { echo "FAIL: $diagrams/$(basename "$f") is not generated by make inventory (remove it)" >&2 && rc=1; }
  done
  [ $rc = 0 ] && echo "inventory-check: */docs/inventory.md and $diagrams/ match the plans"
  return $rc
}

main "$@"
