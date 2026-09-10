{#- Schema naming. On dev the custom schema is used as-is (STAGING / INTERMEDIATE / MARTS / REPORTING): those are
    the schemas Looker Studio and every hand-written query point at, and dbt's default <target>_<custom> would
    rename them on every machine.
    Every OTHER target is prefixed with its own target schema (DBT_CI -> DBT_CI_STAGING, ...), so a CI run on
    synthetic seeds can never write over the real models: without the prefix `--target ci` builds straight into
    MARKETPLACE.STAGING, the same relations as dev. -#}
{% macro generate_schema_name(custom_schema_name, node) -%}
  {%- if custom_schema_name is none -%}
    {{ target.schema }}
  {%- elif target.name == 'dev' -%}
    {{ custom_schema_name | trim }}
  {%- else -%}
    {{ target.schema }}_{{ custom_schema_name | trim }}
  {%- endif -%}
{%- endmacro %}
