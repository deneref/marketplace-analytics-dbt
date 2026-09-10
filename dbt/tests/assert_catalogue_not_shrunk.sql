-- The latest catalogue export must not be much smaller than the recent ones.
-- dim_products takes each SKU from the last snapshot it was seen in, so a partial export (API page lost, loader
-- interrupted) would not break the build by itself — it would silently mark the missing SKUs as "not in the
-- catalogue". This test turns that into an error. The baseline is the largest of the previous seven snapshots,
-- so a partial export that repeats for two days cannot become its own baseline. 80 % leaves room for a real
-- clean-up of a few cards; a deliberate mass delete is a --full-refresh day anyway.
-- Only `dbt build` stops dim_products on this failure; `dbt run` + `dbt test` builds the dim first.

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
        max(n_sku) over (order by snapshot_date rows between 7 preceding and 1 preceding) as n_sku_baseline
    from per_snapshot
    qualify row_number() over (order by snapshot_date desc) = 1

)

select *
from compared
where n_sku_baseline is not null
  and n_sku < 0.8 * n_sku_baseline
