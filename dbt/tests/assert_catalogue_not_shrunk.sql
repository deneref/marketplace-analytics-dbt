-- The latest catalogue export must not be much smaller than the one before it.
-- dim_products takes each SKU from the last snapshot it was seen in, so a partial export (API page lost, loader
-- interrupted) would not break the build by itself — it would silently mark the missing SKUs as "not in the
-- catalogue". This test turns that into an error. 80 % leaves room for a real clean-up of a few cards; a
-- deliberate mass delete is a --full-refresh day anyway.

with per_snapshot as (

    select
        snapshot_date,
        count(distinct sku) as n_sku
    from {{ ref('stg_ym__offers') }}
    group by snapshot_date

),

compared as (

    select
        snapshot_date,
        n_sku,
        lag(n_sku) over (order by snapshot_date) as n_sku_previous
    from per_snapshot
    qualify row_number() over (order by snapshot_date desc) = 1

)

select *
from compared
where n_sku_previous is not null
  and n_sku < 0.8 * n_sku_previous
