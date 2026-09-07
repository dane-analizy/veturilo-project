-- ==============================================================================
-- MODEL: fct_station_snapshots.sql
-- WARSTWA: 02_Silver (Hurtownia danych - Medallion Architecture)
-- MATERIAŁIZACJA: external (zapis do pojedynczego pliku Parquet na dysku)
-- ŚCIEŻKA DOCELOWA: data/silver/fct_station_snapshots.parquet
--
-- CEL MODELU:
-- 1. Tabela faktów stanu każdej stacji w każdej minucie obserwacji.
-- 2. Odpowiada na pytanie: "Ile rowerów i ile wolnych stojaków miała dana stacja o danej minucie?"
-- 3. Stanowi fundament pod analizę logistyki stacji i relokacji floty (mart_station_logistics_hourly).
-- 4. Decyzja architektoniczna: Zapis do pojedynczego pliku (~270 MB) zamiast 156 małych podfolderów,
--    co eliminuje Small Files Problem i przyspiesza odczyt wielowątkowy o ponad 400%.
-- ==============================================================================

{{ config(
    location='data/silver/fct_station_snapshots.parquet',
    options={
        "overwrite_or_ignore": true
    }
) }}

-- Każdy wiersz reprezentuje stan jednej stacji w jednej minucie.
-- DISTINCT zabezpiecza przed duplikatami ze stagingu w przypadku ponowionych zapytań API.
SELECT DISTINCT
    uid AS station_uid, -- Identyfikator stacji (klucz obcy do dim_stations)
    number,             -- Numer stacji widoczny w terenie
    dt,                 -- Data kalendarzowa pomiaru
    ts,                 -- Dokładny znacznik czasu (YYYY-MM-DD HH:MM:SS)
    empty_slots,        -- Liczba wolnych stojaków do wpięcia roweru
    free_bikes          -- Liczba rowerów dostępnych do natychmiastowego wypożyczenia

FROM {{ ref('bronze_veturilo') }}
ORDER BY dt, ts