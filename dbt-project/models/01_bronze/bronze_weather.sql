-- ==============================================================================
-- MODEL: bronze_weather.sql
-- WARSTWA: 01_Bronze (Hurtownia danych - Medallion Architecture)
-- MATERIAŁIZACJA: view (lekki widok w pamięci RAM)
-- ŚCIEŻKA ŹRÓDŁOWA: data/raw/weather.parquet
--
-- CEL MODELU:
-- 1. Formalizacja wejścia surowych danych pogodowych z OpenWeather do DAG-a dbt.
-- 2. Wystawienie danych bez kopiowania ich na dysku (materializacja jako widok).
-- 3. Standaryzacja typów oraz zabezpieczenie brakujących wartości opadów (COALESCE).
-- ==============================================================================

{{ config(
    materialized='view'
) }}

SELECT
    -- Identyfikatory i znaczniki czasu pomiaru pogodowego
    timestamp,
    datetime,

    -- Parametry termiczne (°C)
    temp,
    feels_like,
    temp_min,
    temp_max,

    -- Parametry atmosferyczne (hPa, %)
    pressure,
    humidity,

    -- Parametry wiatru (m/s, stopnie kątowe)
    wind_speed,
    wind_deg,
    wind_gust,

    -- Zachmurzenie i opis słowny stanu pogody
    clouds,
    clouds_description,
    weather_description,

    -- Opady deszczu w mm (wartości NULL zastępowane zerem)
    COALESCE(rain, 0.0) AS rain

FROM read_parquet('data/raw/weather.parquet')
ORDER BY 
    timestamp, datetime
