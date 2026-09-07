#!/bin/bash

# Szukamy wszystkich plików .json w data/raw/veturilo i jej podkatalogach
find data/raw/veturilo -type f -name "*.json" | while read -r file; do

    # Sprawdzamy czy plik jest poprawnym JSON-em ORAZ czy posiada klucz 'network'
    if ! jq -e 'has("network") and .network != null' "$file" >/dev/null 2>&1; then
        echo "Przenoszę uszkodzony / niekompletny plik: $file"

        rel_path="${file#data/raw/veturilo/}"
        dest_path="data/corrupted/$rel_path"

        mkdir -p "$(dirname "$dest_path")"
        mv "$file" "$dest_path"
    fi
done
