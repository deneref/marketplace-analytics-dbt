-- Every (sku, warehouse label) pair of the realization report must be found in dim_products as is.
-- dim_products.warehouse_sku is built by joining the report on sku with a coalesce back to sku, so a join that
-- misses (a case mismatch, a renamed column) would not fail — it would quietly turn K1…K5 back into the seller's
-- codes and break the join of fct_inventory_turnover_monthly. This test makes that miss an error.

with labels as (

    select distinct
        sku,
        warehouse_sku
    from {{ ref('stg_ym__realization_lines') }}
    where warehouse_sku is not null
      and warehouse_sku <> sku

)

select
    l.sku,
    l.warehouse_sku
from labels as l
left join {{ ref('dim_products') }} as d
    on d.sku = l.sku
   and d.warehouse_sku = l.warehouse_sku
where d.sku is null
