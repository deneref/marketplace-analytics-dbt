{#- The marketplace's wall-clock date of a timestamp_tz: the day a status changed as the marketplace saw it.
    One definition for every model that dates a sale by receipt (fct_order_lines.delivered_date,
    dim_products.last_delivered_date) so the two can never drift apart. -#}
{% macro moscow_date(timestamp_tz_column) -%}
    to_date(to_timestamp_ntz(convert_timezone('Europe/Moscow', {{ timestamp_tz_column }})))
{%- endmacro %}
