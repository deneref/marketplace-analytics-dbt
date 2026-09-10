{{ config(severity='warn') }}

-- SKUs that are no longer in the latest catalogue export. dim_products keeps them on purpose (their sales history
-- needs a name and a colour), so this is not a failure — it is the list of cards that were deleted or archived
-- since the previous run, for a person to look at.

select
    sku,
    product_name,
    catalogue_snapshot_date,
    last_delivered_date
from {{ ref('dim_products') }}
where not is_in_catalogue
