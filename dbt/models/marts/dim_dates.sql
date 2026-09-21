-- The calendar: one row per day from the first day of the data to two months ahead, so a report can put a day on
-- the axis even when nothing happened on it (rpt_stock_days is dense over this calendar; a day without a stock
-- report is then a visible hole, not a missing row). Attributes are the ones Looker Studio cannot derive by itself
-- or derives inconsistently: ISO week (Monday-based, the marketplace's business week), month and quarter starts as
-- dates (so a chart can be grouped by them and still sorted chronologically), weekend flag.
-- Grain: date_day. Table, ~700 rows, rebuilt every run (the end moves with today). Start date is a constant on
-- purpose: the first order is 2025-01-10 and the first stock report 2025-01-08.

{{ config(materialized='table') }}

with spine as (

    {{ dbt_utils.date_spine(
        datepart="day",
        start_date="to_date('2025-01-01')",
        end_date="dateadd(day, 61, current_date())"
    ) }}

),

final as (

    select
        date_day::date                                              as date_day,

        -- week (ISO: Monday = 1)
        dayofweekiso(date_day)                                      as day_of_week,
        dayname(date_day)                                           as day_name,
        dayofweekiso(date_day) in (6, 7)                            as is_weekend,
        dateadd(day, 1 - dayofweekiso(date_day), date_day)::date    as iso_week_start_date,    -- Monday, independent of the session's WEEK_START
        weekiso(date_day)                                           as iso_week_number,
        yearofweekiso(date_day)                                     as iso_year,

        -- month
        date_trunc('month', date_day)::date                         as month_start_date,
        month(date_day)                                             as month_number,
        monthname(date_day)                                         as month_name,
        last_day(date_day) = date_day                               as is_month_end,

        -- quarter, year
        date_trunc('quarter', date_day)::date                       as quarter_start_date,
        quarter(date_day)                                           as quarter_number,
        year(date_day)                                              as year_number

    from spine

)

select * from final
