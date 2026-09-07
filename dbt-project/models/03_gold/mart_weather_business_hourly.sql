-- ==============================================================================
-- MODEL: mart_weather_business_hourly.sql
-- WARSTWA: 03_Gold (Hurtownia danych - Medallion Architecture)
-- MATERIAŁIZACJA: external (zapis do pojedynczego pliku Parquet na dysku)
-- ŚCIEŻKA DOCELOWA: data/gold/mart_weather_business_hourly.parquet (~132 KB)
--
-- CEL MODELU:
-- 1. Zestawienie wskaźników biznesowych i ruchu Veturilo z warunkami atmosferycznymi.
-- 2. Ziarno danych: 1 wiersz = 1 godzina całego sezonu rowerowego.
-- 3. Łączy dane pogodowe (fct_weather_hourly) ze skonsolidowanymi podróżami (mart_trips_enriched).
-- 4. Umożliwia natychmiastowe badanie elastyczności popytu, spadku prędkości w czasie opadów
--    oraz wyliczanie strat przychodów w deszczowe dni w Power BI bez żadnych dodatkowych złączeń.
-- ==============================================================================

{{ config(
    location='data/gold/mart_weather_business_hourly.parquet',
    options={
        "overwrite_or_ignore": true
    }
) }}

WITH hourly_trips AS (
    -- Krok 1: Zagregowanie podróży i przychodów do ujęcia godzinowego
    SELECT 
        date_trunc('hour', start_ts)                                    AS hour_ts,
        COUNT(*)                                                        AS total_trips,
        -- Liczba przejazdów, które wygenerowały jakiekolwiek opłaty (> 0 PLN)
        SUM(CASE WHEN estimated_fee_pln > 0 THEN 1 ELSE 0 END)          AS paid_trips,
        -- Przychody: stan rzeczywisty vs symulacja 15 minut
        SUM(estimated_fee_pln)                                          AS total_revenue_pln,
        SUM(simulated_fee_15m_pln)                                      AS simulated_revenue_pln,
        -- Średnie parametry fizyczne ruchu w danej godzinie
        ROUND(AVG(speed_kmh), 2)                                        AS avg_speed_kmh,
        ROUND(AVG(distance_km), 2)                                      AS avg_distance_km
    FROM {{ ref('mart_trips_enriched') }}
    GROUP BY 1
)

SELECT 
    -- Wymiary czasu i kalendarza (z tabeli pogodowej, która gwarantuje ciągłość godzinową)
    w.hour_ts,
    w.dt,
    w.hour_of_day,
    w.day_of_week, -- 1=Poniedziałek, 7=Niedziela
    w.is_weekend,
    
    -- Metryki biznesowe i ruchowe Veturilo (COALESCE zabezpiecza godziny o zerowym ruchu)
    COALESCE(t.total_trips, 0)                                          AS total_trips,
    COALESCE(t.paid_trips, 0)                                           AS paid_trips,
    COALESCE(t.total_revenue_pln, 0.0)                                  AS total_revenue_pln,
    COALESCE(t.simulated_revenue_pln, 0.0)                              AS simulated_revenue_pln,
    COALESCE(t.simulated_revenue_pln - t.total_revenue_pln, 0.0)        AS revenue_uplift_pln,
    t.avg_speed_kmh,
    t.avg_distance_km,
    
    -- Warunki pogodowe w danej godzinie
    w.avg_temp_c,
    w.avg_feels_like_c,
    w.total_rain_mm,
    w.avg_wind_speed_ms,
    w.avg_pressure_hpa,
    w.avg_humidity_pct,
    w.is_rainy,
    w.weather_description

FROM {{ ref('fct_weather_hourly') }} w
LEFT JOIN hourly_trips t ON w.hour_ts = t.hour_ts
ORDER BY w.hour_ts
