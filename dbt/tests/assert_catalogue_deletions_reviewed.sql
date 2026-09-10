{{ config(severity='warn') }}

-- Cards that dropped out of the catalogue during the last week. dim_products keeps them on purpose (their sales
-- history needs a name and a colour), so this is not a failure — it is the list of recent deletions for a person
-- to look at once. Older deletions are not repeated every run: after seven days the row is simply "not in the
-- catalogue" and no longer news.

select
    sku,
    product_name,
    catalogue_snapshot_date,
    last_delivered_date
from {{ ref('dim_products') }}
where not is_in_catalogue
  and catalogue_snapshot_date >= dateadd(day, -7, current_date())
