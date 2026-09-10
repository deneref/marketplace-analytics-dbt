{#- Returns source(source_name, table) normally, or ref('demo_<table>') when var('use_demo_seeds') is true.
    Lets anyone run `dbt build --vars '{"use_demo_seeds": true}'` without API access.
    source_name defaults to 'yandex_market'; the partner's finance workbooks are their own source: source_or_seed('cogs_by_sku', 'finance'). -#}
{% macro source_or_seed(table_name, source_name='yandex_market') %}
  {%- if var('use_demo_seeds', false) -%}
    {{ ref('demo_' ~ table_name) }}
  {%- else -%}
    {{ source(source_name, table_name) }}
  {%- endif -%}
{% endmacro %}
