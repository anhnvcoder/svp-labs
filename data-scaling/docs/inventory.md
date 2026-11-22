# Tài nguyên mỗi root của `data-scaling` tạo trên account trống

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

## `data-scaling/postgres`

- Cả ba phần bật theo `postgres.auto.tfvars.example`: `aurora`, `rds`, `proxy` đều `true`. Tắt một
  phần thì tài nguyên của phần đó (`module.aurora`, `module.rds`, `module.rds_proxy`) rời khỏi plan.
- Khi sinh bảng, khối `ephemeral` thay bằng giá trị giả của `scripts/inventory/data-scaling-postgres.override.hcl`
  (provider giả không trả được ephemeral); ephemeral không phải tài nguyên nên số không đổi.

`Plan: 40 to add, 0 to change, 0 to destroy.`

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../../docs/diagrams/inventory/data-scaling-postgres-dark.svg">
  <img src="../../docs/diagrams/inventory/data-scaling-postgres.svg" alt="Tài nguyên của data-scaling-postgres">
</picture>

| Phần | Tài nguyên |
| --- | ---: |
| `module.aurora` | 7 |
| `module.db_secret` | 2 |
| `module.loader` | 8 |
| `module.network` | 10 |
| `module.rds` | 5 |
| `module.rds_proxy` | 8 |

| Loại | Dịch vụ | Số |
| --- | --- | ---: |
| `aws_db_instance` | RDS | 2 |
| `aws_db_proxy` | RDS | 1 |
| `aws_db_proxy_default_target_group` | RDS | 1 |
| `aws_db_proxy_target` | RDS | 1 |
| `aws_db_subnet_group` | RDS | 2 |
| `aws_iam_instance_profile` | IAM | 1 |
| `aws_iam_role` | IAM | 2 |
| `aws_iam_role_policy` | IAM | 2 |
| `aws_iam_role_policy_attachment` | IAM | 1 |
| `aws_instance` | EC2 | 1 |
| `aws_internet_gateway` | VPC | 1 |
| `aws_rds_cluster` | Aurora | 1 |
| `aws_rds_cluster_instance` | Aurora | 2 |
| `aws_route_table` | VPC | 2 |
| `aws_route_table_association` | VPC | 3 |
| `aws_secretsmanager_secret` | Secrets Manager | 1 |
| `aws_secretsmanager_secret_version` | Secrets Manager | 1 |
| `aws_security_group` | VPC | 4 |
| `aws_subnet` | VPC | 3 |
| `aws_vpc` | VPC | 1 |
| `aws_vpc_security_group_egress_rule` | VPC | 3 |
| `aws_vpc_security_group_ingress_rule` | VPC | 4 |

## `data-scaling/valkey`

- `shards` theo `valkey.auto.tfvars.example` (2). Số shard không đổi số tài nguyên: một replication
  group giữ mọi shard.
- Khi sinh bảng, khối `ephemeral` thay bằng giá trị giả của `scripts/inventory/data-scaling-valkey.override.hcl`
  (provider giả không trả được ephemeral); ephemeral không phải tài nguyên nên số không đổi.

`Plan: 29 to add, 0 to change, 0 to destroy.`

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../../docs/diagrams/inventory/data-scaling-valkey-dark.svg">
  <img src="../../docs/diagrams/inventory/data-scaling-valkey.svg" alt="Tài nguyên của data-scaling-valkey">
</picture>

| Phần | Tài nguyên |
| --- | ---: |
| `module.loader` | 8 |
| `module.network` | 10 |
| `module.valkey` | 11 |

| Loại | Dịch vụ | Số |
| --- | --- | ---: |
| `aws_elasticache_parameter_group` | ElastiCache | 2 |
| `aws_elasticache_replication_group` | ElastiCache | 2 |
| `aws_elasticache_subnet_group` | ElastiCache | 1 |
| `aws_elasticache_user` | ElastiCache | 1 |
| `aws_elasticache_user_group` | ElastiCache | 1 |
| `aws_iam_instance_profile` | IAM | 1 |
| `aws_iam_role` | IAM | 1 |
| `aws_iam_role_policy` | IAM | 1 |
| `aws_iam_role_policy_attachment` | IAM | 1 |
| `aws_instance` | EC2 | 1 |
| `aws_internet_gateway` | VPC | 1 |
| `aws_route_table` | VPC | 2 |
| `aws_route_table_association` | VPC | 3 |
| `aws_secretsmanager_secret` | Secrets Manager | 1 |
| `aws_secretsmanager_secret_version` | Secrets Manager | 1 |
| `aws_security_group` | VPC | 2 |
| `aws_subnet` | VPC | 3 |
| `aws_vpc` | VPC | 1 |
| `aws_vpc_security_group_egress_rule` | VPC | 2 |
| `aws_vpc_security_group_ingress_rule` | VPC | 1 |
