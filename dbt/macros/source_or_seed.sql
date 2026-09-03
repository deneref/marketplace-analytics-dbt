{#- Returns source('yandex_market', table) normally, or ref('demo_<table>') when var('use_demo_seeds') is true.
    Lets anyone run `dbt build --vars '{"use_demo_seeds": true}'` without API access. -#}
{% macro source_or_seed(table_name) %}
  {%- if var('use_demo_seeds', false) -%}
    {{ ref('demo_' ~ table_name) }}
  {%- else -%}
    {{ source('yandex_market', table_name) }}
  {%- endif -%}
{% endmacro %}
