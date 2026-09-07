-- ==============================================================================
-- MODEL: fct_bike_snapshots.sql
-- WARSTWA: 02_Silver (Hurtownia danych - Medallion Architecture)
-- MATERIAŁIZACJA: view (widok wirtualny w pamięci RAM)
--
-- CEL MODELU:
-- 1. Odpowiedź na pytanie operacyjne: "Na jakiej stacji stał dany rower w danej minucie?"
-- 2. Rozwinięcie tablicy identyfikatorów za pomocą UNNEST(bike_uids).
--    Przekształca format szeroki (tablica w wierszu stacji) na relacyjny (1 wiersz = 1 rower).
-- 3. Decyzja architektoniczna: Model NIE jest zapisywany na dysku jako plik Parquet,
--    lecz wystawiony jako widok (view). Służy wyłącznie jako krok pośredni dla fct_bike_trips.
--    Oszczędza to ponad 50 minut niepotrzebnego zapisu ~180 mln wierszy na dysk i ~10 GB miejsca.
-- ==============================================================================

{{ config(
    materialized='view'
) }}

SELECT
    ts,                             -- Timestamp obserwacji z dokładnością do minuty
    dt,                             -- Data obserwacji (klucz partycji)
    uid AS station_uid,             -- Identyfikator stacji, na której stał rower
    unnest(bike_uids) AS bike_uid   -- Pojedynczy identyfikator roweru z rozwiniętej tablicy

FROM {{ ref('bronze_veturilo') }}