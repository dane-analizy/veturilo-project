-- ==============================================================================
-- MODEL: fct_weather_hourly.sql
-- WARSTWA: 02_Silver (Hurtownia danych - Medallion Architecture)
-- MATERIAŁIZACJA: external (zapis do pojedynczego pliku Parquet na dysku)
-- ŚCIEŻKA DOCELOWA: data/silver/fct_weather_hourly.parquet (~65 KB)
--
-- CEL MODELU:
-- 1. Oczyszczenie i zagregowanie surowych pomiarów pogodowych do ziarna 1 godziny (1h).
-- 2. Dynamiczne dopasowanie zakresu dat: CTE bike_date_range pobiera MIN(dt) i MAX(dt)
--    z bronze_veturilo, dzięki czemu model działa automatycznie dla dowolnego roku/sezonu.
-- 3. Ujednolicenie atrybutów kalendarzowych (dt, hour_of_day, day_of_week 1-7, is_weekend).
-- 4. Wyliczenie godzinowych wskaźników atmosferycznych: średnia temperatura, suma opadów, wiatr, ciśnienie.
-- ==============================================================================

{{ config(
    location='data/silver/fct_weather_hourly.parquet',
    options={
        "overwrite_or_ignore": true
    }
) }}

WITH bike_date_range AS (
    -- Dynamiczny zakres dat z danych rowerowych.
    -- DuckDB wyznacza to w ułamku sekundy z metadanych partycji Hive.
    SELECT
        MIN(dt) AS min_dt,
        MAX(dt) AS max_dt
    FROM {{ ref('bronze_veturilo') }}
),

filtered_weather AS (
    -- Filtrujemy wieloletnią historię pogody (od 2022 roku) wyłącznie do aktywnego sezonu Veturilo
    SELECT
        date_trunc('hour', w.datetime)                                AS hour_ts,
        w.temp,
        w.feels_like,
        w.pressure,
        w.humidity,
        w.wind_speed,
        w.wind_deg,
        w.clouds,
        w.weather_description,
        w.rain
    FROM {{ ref('bronze_weather') }} w
    CROSS JOIN bike_date_range r
    WHERE w.datetime >= r.min_dt
      AND w.datetime < (r.max_dt + INTERVAL 1 DAY)
)

SELECT
    hour_ts,
    CAST(hour_ts AS DATE)                                           AS dt,
    EXTRACT('hour' FROM hour_ts)::INT                               AS hour_of_day,
    EXTRACT('isodow' FROM hour_ts)::INT                             AS day_of_week, -- 1=Poniedziałek, 7=Niedziela
    (EXTRACT('isodow' FROM hour_ts) IN (6, 7))                      AS is_weekend,

    -- Metryki termiczne i ciśnienie atmosferyczne
    ROUND(AVG(temp), 1)                                             AS avg_temp_c,
    ROUND(AVG(feels_like), 1)                                       AS avg_feels_like_c,
    ROUND(AVG(pressure), 0)::INT                                    AS avg_pressure_hpa,
    ROUND(AVG(humidity), 0)::INT                                    AS avg_humidity_pct,

    -- Wiatr i zachmurzenie
    ROUND(AVG(wind_speed), 1)                                       AS avg_wind_speed_ms,
    ROUND(AVG(clouds), 0)::INT                                      AS avg_clouds_pct,

    -- Suma opadów deszczu w danej godzinie i flaga deszczu
    ROUND(SUM(rain), 2)                                             AS total_rain_mm,
    CASE WHEN SUM(rain) > 0 THEN TRUE ELSE FALSE END                AS is_rainy,

    -- Dominujący stan nieba w danej godzinie (statystyczna dominanta MODE)
    MODE(weather_description)                                       AS weather_description

FROM filtered_weather
GROUP BY 1
ORDER BY hour_ts
