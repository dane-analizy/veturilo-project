-- ==============================================================================
-- MODEL: dim_station_distances.sql
-- WARSTWA: 02_Silver (Hurtownia danych - Medallion Architecture)
-- MATERIAŁIZACJA: external (zapis do pojedynczego pliku Parquet na dysku)
-- ŚCIEŻKA DOCELOWA: data/silver/dim_station_distances.parquet
--
-- CEL MODELU:
-- 1. Pre-kalkulacja macierzy odległości geodezyjnych między wszystkimi stacjami w Warszawie.
-- 2. Uzasadnienie inżynierskie: Zamiast wywoływać ciężką funkcję ST_Distance_Spheroid
--    dla każdego z milionów przejazdów, liczymy ją raz dla wszystkich unikalnych par:
--    ~350 stacji * 350 stacji = ~122 500 par (plik waży zaledwie ~550 KB).
-- 3. Zastępuje kosztowne, wielokrotne złączenia w modelach przejazdów i martach O-D.
-- ==============================================================================

{{ config(
    location='data/silver/dim_station_distances.parquet',
    options={
        "overwrite_or_ignore": true
    }
) }}

WITH unique_stations AS (
    -- Krok 1: Wymuszenie dokładnie jednego rekordu na station_uid (ochrona przed duplikatami)
    SELECT
        id,
        station_uid,
        name,
        longitude,
        latitude
    FROM {{ ref('dim_stations') }}
    WHERE longitude IS NOT NULL AND latitude IS NOT NULL
    QUALIFY ROW_NUMBER() OVER (PARTITION BY station_uid ORDER BY id) = 1
)

SELECT
    -- Identyfikatory i współrzędne stacji początkowej (Origin)
    s1.station_uid                              AS start_station_uid,
    s1.id                                       AS start_station_id,
    s1.name                                     AS start_station_name,
    s1.longitude                                AS start_longitude,
    s1.latitude                                 AS start_latitude,

    -- Identyfikatory i współrzędne stacji końcowej (Destination)
    s2.station_uid                              AS end_station_uid,
    s2.id                                       AS end_station_id,
    s2.name                                     AS end_station_name,
    s2.longitude                                AS end_longitude,
    s2.latitude                                 AS end_latitude,

    -- Obliczenie odległości na elipsoidzie WGS84 (dokładność geodezyjna w km):
    -- Dla tej samej stacji odległość wynosi dokładnie 0.0 km.
    CASE
        WHEN s1.station_uid = s2.station_uid THEN 0.0
        ELSE ROUND(
            ST_Distance_Spheroid(
                ST_Point(s1.longitude, s1.latitude),
                ST_Point(s2.longitude, s2.latitude)
            ) / 1000.0,
            3
        )
    END AS distance_km

FROM unique_stations s1
CROSS JOIN unique_stations s2
ORDER BY start_station_uid, end_station_uid
