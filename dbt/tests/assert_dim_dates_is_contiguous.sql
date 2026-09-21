-- The calendar has no holes: the number of rows equals the number of days between its first and last day.
-- Everything dense over dim_dates (rpt_stock_days) relies on this.
{{ config(severity='error') }}

select
    min(date_day)                                   as first_day,
    max(date_day)                                   as last_day,
    count(*)                                        as rows_in_table,
    datediff('day', min(date_day), max(date_day)) + 1 as days_expected
from {{ ref('dim_dates') }}
having count(*) <> datediff('day', min(date_day), max(date_day)) + 1
   or count(*) <> count(distinct date_day)
