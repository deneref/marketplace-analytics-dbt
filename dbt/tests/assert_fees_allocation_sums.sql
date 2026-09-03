-- Allocation must neither lose nor create money:
-- sum of fees allocated to order lines == sum of fees per order in the services sheet.
-- TODO(Daniil): point at your intermediate model once written.
{{ config(severity='error', enabled=false) }}

with allocated as (
    select order_id, sum(allocated_fees) as fees from {{ ref('fct_order_items') }} group by 1
),
per_order as (
    select order_id, sum(try_to_decimal(service_amount, 18, 2)) as fees
    from {{ source_or_seed('united_orders_services') }} group by 1
)
select a.order_id, a.fees as allocated, p.fees as reported
from allocated a join per_order p using (order_id)
where abs(a.fees - p.fees) > 0.01
